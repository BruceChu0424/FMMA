#!/usr/bin/env python3
"""Drive the DE1-SoC over its serial console.

The board's UART is often the only link available: JTAG needs a USB-Blaster
and the network needs a route that a lab bench may not have.  This tool
makes the serial console scriptable, so bring-up and testing are repeatable
instead of a person typing into PuTTY.

    python tools/boardctl.py info
    python tools/boardctl.py run "uname -a"
    python tools/boardctl.py push Software/MarketStream.c /root/fmma/
    python tools/boardctl.py pull /root/fmma/run.log logs/
    python tools/boardctl.py shell                # interactive

Transfers go over the console as base64, which is slow (about 6 KB/s at
115200 baud) but needs nothing on the far end except `base64`, which every
image has.  Use `--via-net` once the board has an address; it is hundreds of
times faster.

Design notes
------------
Everything funnels through `Board.run()`, which brackets each command with a
unique marker so the reply can be separated from echo and from anything the
kernel prints.  That is the whole trick to making a serial console reliable:
never parse a prompt, always parse a marker you chose yourself.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import os
import sys
import time
from pathlib import Path

try:
    import serial  # type: ignore
    from serial.tools import list_ports  # type: ignore
except ImportError:                                    # pragma: no cover
    sys.exit("pyserial is required:  python -m pip install pyserial")

DEFAULT_BAUD = 115200
DEFAULT_PROMPT_TIMEOUT = 15.0
CHUNK = 2048                 # base64 payload bytes per line


class BoardError(RuntimeError):
    pass


def find_port(hint=None):
    """Pick the board's serial port.

    A DE1-SoC shows up as a plain USB serial converter, so there is nothing
    in the descriptor that identifies it.  Prefer an explicit --port; when
    guessing, skip Bluetooth ports, which are the usual decoys.
    """
    if hint:
        return hint
    candidates = []
    for p in list_ports.comports():
        desc = f"{p.description} {p.manufacturer or ''}".lower()
        if "bluetooth" in desc or "蓝牙" in p.description:
            continue
        score = 0
        if "usb serial" in desc or "ftdi" in desc or "cp210" in desc:
            score += 10
        candidates.append((score, p.device))
    if not candidates:
        raise BoardError("no candidate serial ports; pass --port COMx")
    candidates.sort(reverse=True)
    return candidates[0][1]


class Board:
    """A scriptable serial console session."""

    def __init__(self, port=None, baud=DEFAULT_BAUD, verbose=False):
        self.port_name = find_port(port)
        self.verbose = verbose
        self.ser = serial.Serial(self.port_name, baud, timeout=0.2,
                                 write_timeout=10)
        time.sleep(0.2)
        self.ser.reset_input_buffer()

    def close(self):
        try:
            self.ser.close()
        except Exception:
            pass

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    # -- primitives ---------------------------------------------------------

    def _write(self, text):
        self.ser.write(text.encode("utf-8", "replace"))
        self.ser.flush()

    def _read_until(self, marker, timeout):
        deadline = time.time() + timeout
        buf = bytearray()
        target = marker.encode()
        while time.time() < deadline:
            chunk = self.ser.read(4096)
            if chunk:
                buf += chunk
                if self.verbose:
                    sys.stderr.write(chunk.decode("utf-8", "replace"))
                    sys.stderr.flush()
                if target in buf:
                    return buf.decode("utf-8", "replace")
            else:
                time.sleep(0.01)
        raise BoardError(
            f"timed out after {timeout:.0f}s waiting for the command to finish.\n"
            f"Last 400 bytes seen:\n{buf[-400:].decode('utf-8', 'replace')}")

    def wake(self):
        """Make sure there is a shell on the other end."""
        self.ser.reset_input_buffer()
        self._write("\r\n")
        time.sleep(0.4)
        self.ser.read(4096)

    # -- the one entry point everything else uses ---------------------------

    def run(self, command, timeout=DEFAULT_PROMPT_TIMEOUT, check=True):
        """Run a shell command; return (exit_code, output).

        The command is bracketed with a unique marker, so the output can be
        separated from the echo and from any kernel chatter without having
        to recognise a prompt.
        """
        tag = f"__FMMA_{os.urandom(4).hex()}__"
        self.ser.reset_input_buffer()
        self._write(f"{command}\necho {tag}$?{tag}\n")
        raw = self._read_until(f"{tag}", timeout)

        # The echo of our own 'echo' line contains the marker too, so take
        # the completed form: TAG<digits>TAG.
        import re
        m = None
        for m in re.finditer(re.escape(tag) + r"(\d+)" + re.escape(tag), raw):
            pass
        if m is None:
            raw += self._read_until(tag, timeout)
            for m in re.finditer(re.escape(tag) + r"(\d+)" + re.escape(tag), raw):
                pass
        if m is None:
            raise BoardError(f"could not find the completion marker in:\n{raw[-400:]}")

        code = int(m.group(1))
        body = raw[:m.start()]
        lines = body.splitlines()
        # Drop the echoed command and the echoed 'echo TAG$?TAG' line.
        cleaned = [ln for ln in lines
                   if tag not in ln and ln.strip() != command.strip()]
        out = "\n".join(cleaned).strip("\r\n")
        if check and code != 0:
            raise BoardError(f"command failed ({code}): {command}\n{out}")
        return code, out

    # -- file transfer ------------------------------------------------------

    def push(self, local, remote_dir, progress=True):
        """Copy a local file to the board over the console."""
        local = Path(local)
        data = local.read_bytes()
        digest = hashlib.md5(data).hexdigest()
        remote = f"{remote_dir.rstrip('/')}/{local.name}"

        self.run(f"mkdir -p {remote_dir}")
        self.run(f"rm -f {remote}.b64 {remote}")

        encoded = base64.b64encode(data).decode()
        total = len(encoded)
        sent = 0
        t0 = time.time()
        for i in range(0, total, CHUNK):
            part = encoded[i:i + CHUNK]
            # printf keeps the shell from interpreting anything in the payload
            self.run(f"printf '%s' '{part}' >> {remote}.b64", timeout=30)
            sent += len(part)
            if progress:
                pct = 100 * sent / total
                rate = len(data) * (sent / total) / max(time.time() - t0, 1e-3)
                sys.stderr.write(f"\r  {local.name}: {pct:5.1f}%  "
                                 f"{rate/1024:.1f} KB/s   ")
                sys.stderr.flush()
        if progress:
            sys.stderr.write("\n")

        self.run(f"base64 -d {remote}.b64 > {remote} && rm -f {remote}.b64",
                 timeout=60)
        _, got = self.run(f"md5sum {remote} | cut -d' ' -f1")
        got = got.strip().splitlines()[-1].strip()
        if got != digest:
            raise BoardError(f"checksum mismatch for {remote}: "
                             f"{got} != {digest}")
        return remote

    def pull(self, remote, local_dir):
        """Copy a file from the board to the host over the console."""
        local_dir = Path(local_dir)
        local_dir.mkdir(parents=True, exist_ok=True)
        _, b64 = self.run(f"base64 {remote}", timeout=300)
        blob = "".join(b64.split())
        dest = local_dir / Path(remote).name
        dest.write_bytes(base64.b64decode(blob))
        return dest

    # -- convenience --------------------------------------------------------

    def info(self):
        """Collect the facts worth knowing before doing anything else."""
        checks = [
            ("kernel", "uname -a"),
            ("uptime", "uptime"),
            ("distro", "cat /etc/os-release 2>/dev/null | head -2 || echo unknown"),
            ("cpu", "grep -m1 'model name' /proc/cpuinfo || head -3 /proc/cpuinfo"),
            ("memory", "free -m | head -2"),
            ("disk", "df -h / | tail -1"),
            ("network", "ip -4 addr show scope global 2>/dev/null | grep inet || ifconfig 2>/dev/null | grep 'inet '"),
            ("route", "ip route 2>/dev/null | head -3 || route -n | head -4"),
            ("dns", "cat /etc/resolv.conf 2>/dev/null | grep -v '^#' | head -3"),
            ("gcc", "gcc --version 2>/dev/null | head -1 || echo 'not installed'"),
            ("openssl-dev", "ls /usr/include/openssl/ssl.h 2>/dev/null || echo 'not installed'"),
            ("python3", "python3 --version 2>&1 | head -1 || echo 'not installed'"),
            ("fpga manager", "ls /sys/class/fpga_manager/ 2>/dev/null || echo 'none'"),
            ("fpga bridges", "ls /sys/class/fpga_bridge/ 2>/dev/null || echo 'none'"),
            ("devmem", "which devmem2 devmem 2>/dev/null || echo 'not installed'"),
            ("/dev/mem", "ls -l /dev/mem 2>/dev/null || echo missing"),
        ]
        out = {}
        for name, cmd in checks:
            try:
                _, text = self.run(cmd, check=False)
            except BoardError as e:
                text = f"<error: {e}>"
            out[name] = text.strip()
        return out


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def cmd_info(board, args):
    facts = board.info()
    width = max(len(k) for k in facts)
    for k, v in facts.items():
        first, *rest = (v or "-").splitlines() or ["-"]
        print(f"{k:<{width}} : {first}")
        for line in rest:
            print(f"{'':<{width}}   {line}")
    return 0


def cmd_run(board, args):
    code, out = board.run(args.command, timeout=args.timeout, check=False)
    if out:
        print(out)
    return code


def cmd_push(board, args):
    for src in args.files:
        dest = board.push(src, args.dest)
        print(f"pushed {src} -> {dest}")
    return 0


def cmd_pull(board, args):
    dest = board.pull(args.remote, args.dest)
    print(f"pulled {args.remote} -> {dest}")
    return 0


def cmd_shell(board, args):
    """A dumb interactive console, for when a human needs to poke around."""
    print(f"connected to {board.port_name}; Ctrl-] to quit")
    import threading

    stop = threading.Event()

    def reader():
        while not stop.is_set():
            data = board.ser.read(1024)
            if data:
                sys.stdout.write(data.decode("utf-8", "replace"))
                sys.stdout.flush()

    t = threading.Thread(target=reader, daemon=True)
    t.start()
    try:
        while True:
            line = sys.stdin.readline()
            if not line or line.strip() == "\x1d":
                break
            board._write(line)
    except KeyboardInterrupt:
        pass
    finally:
        stop.set()
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(description="drive the DE1-SoC over serial")
    p.add_argument("--port", help="serial port (default: autodetect)")
    p.add_argument("--baud", type=int, default=DEFAULT_BAUD)
    p.add_argument("-v", "--verbose", action="store_true",
                   help="echo everything the board sends")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("info", help="report what is on the board").set_defaults(fn=cmd_info)

    r = sub.add_parser("run", help="run a shell command")
    r.add_argument("command")
    r.add_argument("--timeout", type=float, default=DEFAULT_PROMPT_TIMEOUT)
    r.set_defaults(fn=cmd_run)

    u = sub.add_parser("push", help="copy files to the board")
    u.add_argument("files", nargs="+")
    u.add_argument("dest")
    u.set_defaults(fn=cmd_push)

    d = sub.add_parser("pull", help="copy a file from the board")
    d.add_argument("remote")
    d.add_argument("dest")
    d.set_defaults(fn=cmd_pull)

    sub.add_parser("shell", help="interactive console").set_defaults(fn=cmd_shell)

    args = p.parse_args(argv)
    try:
        with Board(args.port, args.baud, args.verbose) as board:
            board.wake()
            return args.fn(board, args)
    except BoardError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
