#!/usr/bin/env python3
"""Drive the DE1-SoC over its serial console.

The board's UART is often the only link available: JTAG needs a USB-Blaster
and the network needs a route that a lab bench may not have.  This tool
makes the serial console scriptable, so bring-up and testing are repeatable
instead of a person typing into PuTTY.

    python tools/boardctl.py info
    python tools/boardctl.py run "uname -a"
    python tools/boardctl.py push Software/src/main.c /root/fmma/src/
    python tools/boardctl.py pull /root/fmma/run.log logs/
    python tools/boardctl.py shell                # interactive

Transfers over the console are base64 at roughly 6 KB/s - fine for a source
file, painful for a bitstream.  `deploy.py` uses HTTP once the board has an
address, which is hundreds of times faster.

Design note: making a serial console scriptable
-----------------------------------------------
The console echoes back everything it is sent, so the reply arrives mixed
in with a copy of the request.  Worse, a long command wraps, and the
terminal inserts cursor-movement escapes in the middle of the echo, so the
request cannot simply be matched and deleted.

The way out is to have the far end build the markers from shell variables.
What gets echoed is `printf '%s\\n' "${S}@"`, never the expanded marker, so
the first literal occurrence of the marker in the stream is guaranteed to be
real output.  Everything funnels through Board.run(), which does that once
and correctly.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import os
import re
import sys
import time
from pathlib import Path

try:
    import serial  # type: ignore
    from serial.tools import list_ports  # type: ignore
except ImportError:                                    # pragma: no cover
    sys.exit("pyserial is required:  python -m pip install pyserial")

DEFAULT_BAUD = 115200
DEFAULT_TIMEOUT = 20.0
CHUNK = 2048                 # base64 payload characters per console write

_CSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")


class BoardError(RuntimeError):
    pass


def find_port(hint=None):
    """Pick the board's serial port.

    A DE1-SoC shows up as a plain USB serial converter, so nothing in the
    descriptor identifies it.  Prefer an explicit --port; when guessing,
    skip Bluetooth ports, which are the usual decoys.
    """
    if hint:
        return hint
    candidates = []
    for p in list_ports.comports():
        desc = f"{p.description} {p.manufacturer or ''}".lower()
        if "bluetooth" in desc or "蓝牙" in p.description:
            continue
        score = 10 if ("usb serial" in desc or "ftdi" in desc
                       or "cp210" in desc) else 0
        candidates.append((score, p.device))
    if not candidates:
        raise BoardError("no candidate serial ports; pass --port COMx")
    candidates.sort(reverse=True)
    return candidates[0][1]


def _clean(text):
    """Strip terminal escapes, our own epilogue and blank edges."""
    text = _CSI.sub("", text).replace("\r", "")
    lines = []
    for ln in text.split("\n"):
        # The shell echoes the second line we send - the one that
        # captures $? and prints the end marker - and that echo lands
        # inside the captured body. It is the only place this token can
        # come from, so dropping it is unambiguous.
        if "__rc=$?" in ln:
            continue
        lines.append(ln)
    while lines and not lines[0].strip():
        lines.pop(0)
    while lines and not lines[-1].strip():
        lines.pop()
    return "\n".join(lines)


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

    def wake(self):
        """Make sure there is a shell on the other end."""
        self.ser.reset_input_buffer()
        self._write("\r\n")
        time.sleep(0.4)
        self.ser.read(8192)

    # -- the one entry point everything else uses ---------------------------

    def run(self, command, timeout=DEFAULT_TIMEOUT, check=True):
        """Run a shell command; return (exit_code, output)."""
        tag = os.urandom(5).hex()
        s_mark = "@FS" + tag + "@"
        e_mark = "@FE" + tag + "@"

        # The assignments hold the marker minus its final '@', so the
        # complete marker never appears in what the console echoes back.
        wrapped = (
            "S='@FS" + tag + "'; E='@FE" + tag + "'; "
            "printf '%s\\n' \"${S}@\"; "
            + command + "\n"
            "__rc=$?; printf '%s%d%s\\n' \"${E}@\" $__rc \"${E}@\"\n"
        )

        self.ser.reset_input_buffer()
        self._write(wrapped)

        pattern = re.compile(re.escape(e_mark) + r"(\d+)" + re.escape(e_mark))
        deadline = time.time() + timeout
        buf = ""

        while time.time() < deadline:
            chunk = self.ser.read(4096)
            if not chunk:
                time.sleep(0.01)
                continue
            text = chunk.decode("utf-8", "replace")
            if self.verbose:
                sys.stderr.write(text)
                sys.stderr.flush()
            buf += text

            m = pattern.search(buf)
            if m is None:
                continue

            body = buf[:m.start()]
            i = body.find(s_mark)
            if i >= 0:
                body = body[i + len(s_mark):]
            code = int(m.group(1))
            out = _clean(body)
            if check and code != 0:
                raise BoardError(f"command failed ({code}): {command}\n{out}")
            return code, out

        raise BoardError(
            "timed out after %.0fs waiting for the command to finish.\n"
            "Last 400 characters seen:\n%s" % (timeout, buf[-400:]))

    # -- file transfer ------------------------------------------------------

    def push(self, local, remote_dir, progress=True):
        """Copy a local file to the board over the console, as base64."""
        local = Path(local)
        data = local.read_bytes()
        digest = hashlib.md5(data).hexdigest()
        remote = remote_dir.rstrip("/") + "/" + local.name

        self.run("mkdir -p " + remote_dir)
        self.run("rm -f %s.b64 %s" % (remote, remote))

        encoded = base64.b64encode(data).decode()
        total = len(encoded)
        t0 = time.time()
        for i in range(0, total, CHUNK):
            part = encoded[i:i + CHUNK]
            # printf keeps the shell from interpreting the payload.
            self.run("printf '%%s' '%s' >> %s.b64" % (part, remote),
                     timeout=60)
            if progress:
                sent = min(i + CHUNK, total)
                rate = len(data) * (sent / total) / max(time.time() - t0, 1e-3)
                sys.stderr.write("\r  %s: %5.1f%%  %.1f KB/s   "
                                 % (local.name, 100 * sent / total,
                                    rate / 1024))
                sys.stderr.flush()
        if progress:
            sys.stderr.write("\n")

        self.run("base64 -d %s.b64 > %s && rm -f %s.b64"
                 % (remote, remote, remote), timeout=120)
        _, got = self.run("md5sum %s | cut -d' ' -f1" % remote, timeout=60)
        got = got.strip().splitlines()[-1].strip()
        if got != digest:
            raise BoardError("checksum mismatch for %s: %s != %s"
                             % (remote, got, digest))
        return remote

    def pull(self, remote, local_dir):
        """Copy a file from the board to the host over the console."""
        local_dir = Path(local_dir)
        local_dir.mkdir(parents=True, exist_ok=True)
        _, b64 = self.run("base64 " + remote, timeout=300)
        dest = local_dir / Path(remote).name
        dest.write_bytes(base64.b64decode("".join(b64.split())))
        return dest

    # -- convenience --------------------------------------------------------

    def info(self):
        """Collect the facts worth knowing before doing anything else."""
        checks = [
            ("kernel", "uname -a"),
            ("uptime", "uptime"),
            ("cpu", "grep -m1 'model name' /proc/cpuinfo || head -1 /proc/cpuinfo"),
            ("memory", "free -m | sed -n 2p"),
            ("disk", "df -h / | tail -1"),
            ("ip", "ip -4 -o addr show eth0 2>/dev/null | awk '{print $4}'"),
            ("route", "ip route 2>/dev/null | sed -n 1p"),
            ("dns", "grep nameserver /etc/resolv.conf 2>/dev/null | head -2"),
            ("gcc", "gcc -dumpversion 2>/dev/null || echo none"),
            ("openssl-dev", "test -f /usr/include/openssl/ssl.h && echo present || echo absent"),
            ("fpga manager", "ls /sys/class/fpga/ 2>/dev/null || echo none"),
            ("fpga bridges", "ls /sys/class/fpga-bridge/ 2>/dev/null | tr '\\n' ' '"),
            ("fpga status", "cat /sys/class/fpga/fpga0/status 2>/dev/null || echo unknown"),
            ("/dev/mem", "test -c /dev/mem && echo present || echo missing"),
        ]
        out = {}
        for name, cmd in checks:
            try:
                _, text = self.run(cmd, check=False)
            except BoardError as e:
                text = "<error: %s>" % e
            out[name] = text.strip()
        return out


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def cmd_info(board, args):
    facts = board.info()
    width = max(len(k) for k in facts)
    for k, v in facts.items():
        parts = (v or "-").splitlines() or ["-"]
        print("%-*s : %s" % (width, k, parts[0]))
        for line in parts[1:]:
            print("%-*s   %s" % (width, "", line))
    return 0


def cmd_run(board, args):
    code, out = board.run(args.command, timeout=args.timeout, check=False)
    if out:
        print(out)
    return code


def cmd_push(board, args):
    for src in args.files:
        print("pushed %s -> %s" % (src, board.push(src, args.dest)))
    return 0


def cmd_pull(board, args):
    print("pulled %s -> %s" % (args.remote, board.pull(args.remote, args.dest)))
    return 0


def cmd_shell(board, args):
    """A dumb interactive console, for when a human needs to poke around."""
    import threading
    print("connected to %s; type .quit to leave" % board.port_name)
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
        for line in sys.stdin:
            if line.strip() == ".quit":
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

    sub.add_parser("info", help="report what is on the board") \
       .set_defaults(fn=cmd_info)

    r = sub.add_parser("run", help="run a shell command")
    r.add_argument("command")
    r.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT)
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
        print("error: %s" % e, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
