#!/usr/bin/env python3
"""Deploy and run FMMA on a DE1-SoC.

Automates the runbook in docs/11-board-bringup.md so a bring-up is one
command instead of twenty, and so it is the same twenty every time.

    python tools/deploy.py status          what state is the board in?
    python tools/deploy.py net             bring up Ethernet (DHCP)
    python tools/deploy.py fpga            program the FPGA, safely
    python tools/deploy.py restore         put the stock bitstream back
    python tools/deploy.py push            copy the software over
    python tools/deploy.py build           compile it on the board
    python tools/deploy.py probe           check the HPS/FPGA link
    python tools/deploy.py run -- --dry-run   run the application
    python tools/deploy.py all             everything, in order

The serial console is the control channel because it is the one that
always works.  Bulk data goes over HTTP once the board has an address -
2 MB over the console takes minutes, over the network it takes a second.

----------------------------------------------------------------------
The safety rule this tool exists to enforce
----------------------------------------------------------------------
On Cyclone V there is no timeout on the HPS-to-FPGA bridge.  Reading it
when the fabric is unconfigured issues an AXI transaction that never
completes, and the board hangs hard enough to need a power cycle.  It
is not recoverable in software and it happened during this project's
own bring-up.

So `fpga` never reports success on the FPGA manager's status alone: it
also checks the kernel log for a configuration timeout, and if anything
looks wrong it puts the stock bitstream back before returning.  Nothing
here touches the bridge until that has passed.
"""

from __future__ import annotations

import argparse
import functools
import hashlib
import http.server
import os
import socket
import socketserver
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from boardctl import Board, BoardError          # noqa: E402

REPO = Path(__file__).resolve().parent.parent
REMOTE_DIR = "/root/fmma"
MANIFEST = ".fmma-manifest"      # list of pushed files, used to fix mtimes
STOCK_RBF = "/media/fat_partition/soc_system.rbf"
BRIDGES = ("fpga2hps", "hps2fpga", "lwhps2fpga")


# ---------------------------------------------------------------------------
# A short-lived HTTP server, so the board can pull files quickly
# ---------------------------------------------------------------------------

class _QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass


class FileServer:
    """Serves a staging directory on the LAN for the duration of a deploy."""

    def __init__(self, root, port=0):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)
        handler = functools.partial(_QuietHandler, directory=str(self.root))
        socketserver.TCPServer.allow_reuse_address = True
        self.httpd = socketserver.TCPServer(("0.0.0.0", port), handler)
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever,
                                       daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *exc):
        self.httpd.shutdown()
        self.httpd.server_close()

    def stage(self, path, name=None):
        src = Path(path)
        dest = self.root / (name or src.name)
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(src.read_bytes())
        return dest.relative_to(self.root).as_posix()

    def url_for(self, rel, host_ip):
        return f"http://{host_ip}:{self.port}/{rel}"


def host_ip_for(board_ip):
    """Which of this machine's addresses can the board reach us on?"""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect((board_ip, 9))
        return s.getsockname()[0]
    finally:
        s.close()


# ---------------------------------------------------------------------------
# Board operations
# ---------------------------------------------------------------------------

def board_ip(board):
    _, out = board.run(
        "ip -4 addr show eth0 2>/dev/null | sed -n 's/.*inet \\([0-9.]*\\).*/\\1/p'",
        check=False)
    for line in out.splitlines():
        line = line.strip()
        if line and line[0].isdigit():
            return line
    return None


def fabric_status(board):
    _, out = board.run("cat /sys/class/fpga/fpga0/status 2>/dev/null || "
                       "cat /sys/class/fpga_manager/fpga0/state 2>/dev/null || "
                       "echo 'no fpga manager'", check=False)
    return out.strip().splitlines()[-1].strip() if out.strip() else "unknown"


# MSEL[4:0], read from the FPGA manager status register.  Only the FPP
# modes let the HPS configure the fabric; in AS mode the FPGA loads
# itself from the on-board serial flash and the driver refuses with
# "Invalid MSEL setting".
MSEL_MODES = {
    0b10010: ("AS",     False, "FPGA configures itself from EPCQ flash"),
    0b10011: ("AS",     False, "FPGA configures itself from EPCQ flash"),
    0b10000: ("PS",     False, "passive serial"),
    0b10001: ("PS",     False, "passive serial"),
    0b01000: ("FPPx8",  True,  ""),
    0b01001: ("FPPx8",  True,  ""),
    0b01010: ("FPPx16", True,  ""),
    0b01011: ("FPPx16", True,  ""),
    0b00000: ("FPPx32", True,  ""),
    0b00001: ("FPPx32", True,  ""),
}


def read_msel(board):
    """Return (msel, name, hps_can_configure), or None if it cannot be read.

    Builds tools/msel.c on the board and runs it.  That reads an HPS
    peripheral register, not the FPGA bridge, so it is safe whatever
    state the fabric is in.
    """
    try:
        # Prefer a helper that is already there.  This check must not
        # need the network: --remote exists for people whose network
        # transfer is failing, and silently dropping the MSEL guard for
        # exactly those users would be the wrong way round.
        code, _ = board.run(f"test -x {REMOTE_DIR}/msel", check=False)

        if code != 0:
            ip = board_ip(board)
            if not ip:
                print("  (cannot check MSEL: no network and no msel helper "
                      "on the board)")
                return None
            with FileServer(REPO / "build" / "stage") as srv:
                host = host_ip_for(ip)
                rel = srv.stage(REPO / "tools" / "msel.c")
                board.run(f"mkdir -p {REMOTE_DIR}", check=False)
                board.run(f"wget -q -O {REMOTE_DIR}/msel.c --timeout=30 "
                          f"'{srv.url_for(rel, host)}'", timeout=60)
            code, _ = board.run(f"cd {REMOTE_DIR} && gcc -O2 -o msel msel.c",
                                timeout=120, check=False)
            if code != 0:
                print("  (cannot check MSEL: msel.c did not build)")
                return None

        code, out = board.run(f"{REMOTE_DIR}/msel 2>/dev/null", check=False)
        if code != 0:
            print("  (cannot check MSEL: the helper would not run)")
            return None
    except BoardError:
        print("  (cannot check MSEL: the board did not answer)")
        return None

    for line in reversed(out.strip().splitlines()):
        line = line.strip()
        if line.isdigit():
            msel = int(line)
            name, ok, _note = MSEL_MODES.get(msel, ("unknown", False, ""))
            return msel, name, ok
    return None


def explain_msel(msel, name):
    print(f"  MSEL[4:0] = {msel:05b} ({name})")
    print()
    print("  The HPS can only configure the FPGA in an FPP mode. Set SW10")
    print("  (the 6-position DIP switch) to MSEL = 01010 (FPPx16):")
    print()
    print("      SW10.1 = MSEL0 = 0  -> ON")
    print("      SW10.2 = MSEL1 = 1  -> OFF")
    print("      SW10.3 = MSEL2 = 0  -> ON")
    print("      SW10.4 = MSEL3 = 1  -> OFF")
    print("      SW10.5 = MSEL4 = 0  -> ON")
    print()
    print("  Then power-cycle the board. Alternatively, program over JTAG")
    print("  with a USB-Blaster, which works in any mode.")


def cmd_status(board, args):
    print(f"serial      : {board.port_name}")
    ip = board_ip(board)
    print(f"board IP    : {ip or 'none (run: deploy.py net)'}")
    print(f"FPGA        : {fabric_status(board)}")
    info = read_msel(board)
    if info is None:
        print("MSEL        : could not read")
    else:
        msel, name, ok = info
        print(f"MSEL        : {msel:05b} ({name}) - HPS configuration "
              f"{'available' if ok else 'BLOCKED'}")
        if not ok:
            explain_msel(msel, name)
    # One command per call: the console echoes what it is given, and a
    # compound line wraps, which makes the echo impossible to strip.
    for label, cmd in (("kernel", "uname -r"),
                       ("gcc", "gcc -dumpversion 2>/dev/null || echo none")):
        _, out = board.run(cmd, check=False)
        line = out.strip().splitlines()[-1].strip() if out.strip() else "?"
        print(f"{label:<12}: {line}")
    _, out = board.run(f"ls {REMOTE_DIR} 2>/dev/null | tr '\\n' ' '", check=False)
    print(f"deployed    : {out.strip() or '(nothing)'}")
    return 0


def cmd_net(board, args):
    print("requesting a DHCP lease on eth0...")
    board.run("ip link set eth0 up", check=False)
    board.run("(dhclient -v eth0 2>&1 | tail -3) || "
              "(udhcpc -i eth0 -n -q 2>&1 | tail -3)",
              timeout=90, check=False)
    ip = board_ip(board)
    if not ip:
        print("no address; is a cable plugged into a router?")
        return 1
    print(f"board is at {ip}")

    # These images boot with the clock at the epoch, which makes every
    # freshly copied source file look like it is from the future and
    # makes `make` complain about all of them.
    import datetime
    now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    board.run(f'date -s "{now}" >/dev/null 2>&1 || true', check=False)
    _, out = board.run("ping -c 2 -W 3 8.8.8.8 2>&1 | tail -1", timeout=30,
                       check=False)
    print(f"internet: {out.strip()}")
    return 0


def _upload(board, srv, host, files):
    """Copy files to the board as one tarball.

    Sending them individually means a serial round trip per file, which
    is both slow and fragile - the console has to stay in step for
    thirty-five consecutive commands.  One archive is a single wget, a
    single checksum and a single untar.
    """
    import io
    import tarfile

    # A manifest travels with the archive so the board can touch exactly
    # the files that arrived - see the note below the untar.
    manifest = "".join(remote + "\n" for _, remote in files).encode()

    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        for local, remote in files:
            tar.add(str(local), arcname=remote)
        entry = tarfile.TarInfo(MANIFEST)
        entry.size = len(manifest)
        tar.addfile(entry, io.BytesIO(manifest))
    blob = buf.getvalue()

    staging = Path(srv.root) / "fmma-src.tar.gz"
    staging.write_bytes(blob)
    want = hashlib.md5(blob).hexdigest()
    url = srv.url_for("fmma-src.tar.gz", host)

    print(f"  {len(files)} files, {len(blob) // 1024} KB compressed")
    board.run(f"mkdir -p {REMOTE_DIR}")
    board.run(f"wget -q -O {REMOTE_DIR}/src.tar.gz --timeout=120 '{url}'",
              timeout=240)
    _, got = board.run(f"md5sum {REMOTE_DIR}/src.tar.gz | cut -d' ' -f1",
                       timeout=60)
    got = got.strip().splitlines()[-1].strip()
    if got != want:
        raise BoardError(f"checksum mismatch: {got} != {want}")
    board.run(f"cd {REMOTE_DIR} && tar xzf src.tar.gz && rm -f src.tar.gz",
              timeout=120)

    # tar restores the host's modification times, and the board's clock
    # is rarely in step with the host's - it is usually behind, so the
    # sources land looking older than binaries built from the previous
    # push and make quietly decides there is nothing to do.  You then
    # test the old binary and cannot work out why the fix did nothing.
    #
    # Touching the whole directory is not the answer either: that stamps
    # the binaries as well, leaving them the same age as their sources,
    # which make also reads as up to date.  Only the files that actually
    # arrived get touched, which is what the manifest is for.
    board.run(f"cd {REMOTE_DIR} && xargs touch < {MANIFEST} "
              f"&& rm -f {MANIFEST}", timeout=120)
    print("  unpacked")


def cmd_fpga(board, args):
    # --remote: the bitstream is already on the board, put there by
    # whatever means suits - scp, a file manager, a USB stick.  The
    # transfer is the least interesting part of this command; the
    # bridge sequencing and the checks around it are the part worth
    # keeping, and doing those by hand is how a board gets hung.
    if args.remote:
        print(f"using the bitstream already on the board: {args.remote}")
        code, _ = board.run(f"test -s {args.remote}", check=False)
        if code != 0:
            print(f"  {args.remote} is missing or empty on the board")
            return 1
        return _program(board, args.remote, restore_on_failure=True)

    rbf = Path(args.rbf or REPO / "output_files" / "HFTTop.rbf")
    if not rbf.is_file():
        print(f"{rbf} not found. It is committed, so a clean checkout has")
        print("it; otherwise regenerate it with:")
        print("  quartus_cpf -c -o bitstream_compression=on "
              "output_files/HFTTop.sof output_files/HFTTop.rbf")
        return 1

    ip = board_ip(board)
    if not ip:
        print("the board has no address; run: deploy.py net")
        return 1

    with FileServer(REPO / "build" / "stage") as srv:
        host = host_ip_for(ip)
        rel = srv.stage(rbf)
        print(f"transferring {rbf.name} ({rbf.stat().st_size} bytes)")
        board.run(f"wget -q -O /root/fmma.rbf --timeout=120 "
                  f"'{srv.url_for(rel, host)}'", timeout=240)
        want = hashlib.md5(rbf.read_bytes()).hexdigest()
        _, got = board.run("md5sum /root/fmma.rbf | cut -d' ' -f1")
        if got.strip().splitlines()[-1].strip() != want:
            print("checksum mismatch after transfer")
            return 1

    return _program(board, "/root/fmma.rbf", restore_on_failure=True)


def cmd_restore(board, args):
    print("restoring the stock bitstream from the SD card")
    return _program(board, STOCK_RBF, restore_on_failure=False)


def _program(board, path, restore_on_failure):
    """Program the fabric and prove it worked before anyone touches it."""
    # Refuse early and usefully if the board is not strapped for HPS
    # configuration: the driver's own error is just "Invalid MSEL
    # setting" followed by a timeout, which explains nothing.
    info = read_msel(board)
    if info is not None:
        msel, name, ok = info
        if not ok:
            print(f"  cannot configure from the HPS in {name} mode")
            explain_msel(msel, name)
            return 1
        print(f"  MSEL = {msel:05b} ({name}) - the HPS can configure the FPGA")

    print("  disabling the bridges")
    for b in BRIDGES:
        board.run(f"echo 0 > /sys/class/fpga-bridge/{b}/enable", check=False)

    # Count configuration timeouts before and after, rather than trying to
    # mark the log: a marker that fails to write makes an old timeout look
    # like a new one, and then even a good bitstream is reported as failed.
    _, before = board.run("dmesg | grep -c 'fpgamgr: timeout' || true",
                          check=False)

    print("  writing the bitstream")
    board.run(f"dd if={path} of=/dev/fpga0 bs=1M 2>&1 | tail -1", timeout=120)
    time.sleep(2)

    status = fabric_status(board)
    _, after = board.run("dmesg | grep -c 'fpgamgr: timeout' || true",
                         check=False)

    def _count(text):
        for line in reversed(text.strip().splitlines()):
            line = line.strip()
            if line.isdigit():
                return int(line)
        return 0

    timed_out = _count(after) > _count(before)
    print(f"  FPGA manager reports: {status}")

    if status != "user mode" or timed_out:
        print("  configuration FAILED")
        if timed_out:
            print("  the FPGA manager timed out - the bitstream was rejected")
        print("  NOT enabling the bridges: an access to an unconfigured")
        print("  fabric would hang the board and need a power cycle")
        if restore_on_failure:
            print("  putting the stock bitstream back so the board stays usable")
            _program(board, STOCK_RBF, restore_on_failure=False)
        return 1

    print("  enabling the bridges")
    for b in BRIDGES:
        board.run(f"echo 1 > /sys/class/fpga-bridge/{b}/enable", check=False)
    print(f"  done: {fabric_status(board)}")
    return 0


SOFTWARE_FILES = [
    ("Software/Makefile",            "Makefile"),
    ("Software/fmma_protocol.h",     "fmma_protocol.h"),
    ("Software/fpga_program.h",      "fpga_program.h"),
    ("Software/third_party/mongoose.c", "third_party/mongoose.c"),
    ("Software/third_party/mongoose.h", "third_party/mongoose.h"),
]


def _source_files():
    files = list(SOFTWARE_FILES)
    for p in sorted((REPO / "Software" / "src").glob("*.[ch]")):
        files.append((f"Software/src/{p.name}", f"src/{p.name}"))
    for p in sorted((REPO / "Software" / "tests").glob("*.c")):
        files.append((f"Software/tests/{p.name}", f"tests/{p.name}"))
    return files


def cmd_push(board, args):
    ip = board_ip(board)
    if not ip:
        print("the board has no address; run: deploy.py net")
        return 1
    files = [(REPO / a, b) for a, b in _source_files()]
    missing = [str(a) for a, _ in files if not a.is_file()]
    if missing:
        print("missing locally:", ", ".join(missing))
        return 1
    with FileServer(REPO / "build" / "stage") as srv:
        host = host_ip_for(ip)
        print(f"copying {len(files)} files to {REMOTE_DIR}")
        _upload(board, srv, host, files)
    return 0


#: Cross-built products, and whether the board can manage without them.
BINARIES = [
    ("marketstream", True),    # needs OpenSSL headers the board has not got
    ("fmma-probe",   False),   # builds on the board in a second
    ("fmma-bench",   False),
]


def cmd_pushbin(board, args):
    """Upload binaries built by tools/crossbuild.sh.

    The board cannot build marketstream: its image has libssl.so but no
    headers, and its Ubuntu 12.04 archives no longer exist, so there is
    nothing to install.  The two diagnostics do build there - they are
    sent as well only because having all three from one toolchain
    removes a variable when something misbehaves.
    """
    ip = board_ip(board)
    if not ip:
        print("the board has no address; run: deploy.py net")
        return 1

    files, missing = [], []
    for name, required in BINARIES:
        path = REPO / "Software" / name
        if path.is_file():
            files.append((path, name))
        elif required:
            missing.append(name)

    if missing:
        print("not built:", ", ".join(missing))
        print("run tools/crossbuild.sh first")
        return 1
    if not files:
        print("nothing to send")
        return 1

    with FileServer(REPO / "build" / "stage") as srv:
        print(f"copying {len(files)} binaries to {REMOTE_DIR}")
        _upload(board, srv, host_ip_for(ip), files)

    board.run(f"cd {REMOTE_DIR} && chmod +x " +
              " ".join(n for _, n in files))
    _, out = board.run(f"cd {REMOTE_DIR} && ls -l " +
                       " ".join(n for _, n in files), check=False)
    print(out)
    return 0


def cmd_build(board, args):
    print("building on the board")
    code, out = board.run(
        f"cd {REMOTE_DIR} && make {args.target} 2>&1 | tail -25",
        timeout=600, check=False)
    print(out)
    if code != 0:
        print("build FAILED")
        return 1
    _, out = board.run(f"ls -la {REMOTE_DIR}/marketstream "
                       f"{REMOTE_DIR}/fmma-probe 2>/dev/null", check=False)
    print(out)
    return 0


def cmd_probe(board, args):
    status = fabric_status(board)
    if status != "user mode":
        print(f"refusing to probe: the FPGA reports '{status}'")
        print("an access to an unconfigured fabric hangs the board")
        return 1
    code, out = board.run(f"cd {REMOTE_DIR} && ./fmma-probe {args.what}",
                          timeout=120, check=False)
    print(out)
    return code


def cmd_run(board, args):
    extra = " ".join(args.args)
    status = fabric_status(board)
    if "--no-fpga" not in extra and status != "user mode":
        print(f"refusing to run: the FPGA reports '{status}'")
        return 1
    print(f"running: marketstream {extra}")
    print("(output follows; Ctrl-C here stops waiting, not the board)")
    code, out = board.run(
        f"cd {REMOTE_DIR} && timeout {args.seconds} "
        f"./marketstream {extra} 2>&1 | tail -60",
        timeout=args.seconds + 60, check=False)
    print(out)
    return 0


def cmd_all(board, args):
    steps = [("net", cmd_net), ("fpga", cmd_fpga), ("push", cmd_push),
             ("build", cmd_build), ("probe", cmd_probe)]
    for name, fn in steps:
        print(f"\n=== {name} ===")
        rc = fn(board, args)
        if rc != 0:
            print(f"stopped at '{name}'")
            return rc
    return 0


# ---------------------------------------------------------------------------

def main(argv=None):
    p = argparse.ArgumentParser(description="deploy FMMA to a DE1-SoC")
    p.add_argument("--port", help="serial port (default: autodetect)")
    p.add_argument("-v", "--verbose", action="store_true")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("status").set_defaults(fn=cmd_status)
    sub.add_parser("net").set_defaults(fn=cmd_net)

    f = sub.add_parser("fpga", help="program the FPGA")
    f.add_argument("rbf", nargs="?",
                   help="bitstream on THIS machine (default: "
                        "output_files/HFTTop.rbf); it is sent over HTTP")
    f.add_argument("--remote", metavar="PATH",
                   help="bitstream already on the BOARD, e.g. "
                        "/home/root/HFTTop.rbf - skips the transfer and "
                        "just programs it, with all the usual checks")
    f.set_defaults(fn=cmd_fpga)

    sub.add_parser("restore", help="reload the stock bitstream") \
       .set_defaults(fn=cmd_restore)
    sub.add_parser("push", help="copy the software").set_defaults(fn=cmd_push)

    sub.add_parser("pushbin", help="copy binaries from tools/crossbuild.sh") \
       .set_defaults(fn=cmd_pushbin)

    b = sub.add_parser("build")
    b.add_argument("target", nargs="?", default="")
    b.set_defaults(fn=cmd_build)

    pr = sub.add_parser("probe")
    pr.add_argument("what", nargs="?", default="")
    pr.set_defaults(fn=cmd_probe)

    r = sub.add_parser("run")
    r.add_argument("--seconds", type=int, default=60)
    r.add_argument("args", nargs=argparse.REMAINDER)
    r.set_defaults(fn=cmd_run)

    a = sub.add_parser("all", help="net, fpga, push, build, probe")
    a.add_argument("rbf", nargs="?")
    a.set_defaults(fn=cmd_all, target="", what="")

    args = p.parse_args(argv)
    # Subcommands share one namespace because `all` reruns the others
    # with it, so anything cmd_fpga reads has to exist either way.
    if not hasattr(args, "rbf"):
        args.rbf = None
    if not hasattr(args, "remote"):
        args.remote = None

    try:
        with Board(args.port, verbose=args.verbose) as board:
            board.wake()
            return args.fn(board, args)
    except BoardError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
