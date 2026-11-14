#!/usr/bin/env python3
"""Phase 5 spike: a transparent PTY proxy. Runs argv on an inner PTY and relays both ways, logging every chunk.

Run as the child of a Harf Session (src/agents_spike_test.zig). The log then has what the program wrote (its
queries and drawing: "OUT") and what Harf answered or the user typed ("IN"), with the time since start in seconds.
Usage: HARF_PROXY_LOG=<file> [HARF_AGENT_CWD=<dir>] agent-proxy.py <program> [args...]
"""
import fcntl, os, pty, select, signal, struct, sys, termios, time, tty

log = open(os.environ["HARF_PROXY_LOG"], "w", buffering=1)
t0 = time.monotonic()


def note(tag, data):
    log.write("%7.3f %s %r\n" % (time.monotonic() - t0, tag, data))


def copy_size(src, dst):
    fcntl.ioctl(dst, termios.TIOCSWINSZ, fcntl.ioctl(src, termios.TIOCGWINSZ, b"\0" * 8))


# The program must not think it is nested in Claude Code, and `zig build test` sets NO_COLOR, which a real Harf window never does.
env = {k: v for k, v in os.environ.items() if not k.startswith(("CLAUDE", "AI_AGENT")) and k != "NO_COLOR"}
pid, master = pty.fork()
if pid == 0:
    if os.environ.get("HARF_AGENT_CWD"):
        os.chdir(os.environ["HARF_AGENT_CWD"])
    os.execvpe(sys.argv[1], sys.argv[1:], env)

copy_size(0, master)
signal.signal(signal.SIGWINCH, lambda *_: copy_size(0, master))  # the kernel tells the program
saved = termios.tcgetattr(0)
tty.setraw(0)
status = 0
try:
    while True:
        try:
            ready, _, _ = select.select([0, master], [], [])
        except InterruptedError:
            continue
        if 0 in ready:
            data = os.read(0, 65536)
            if not data:
                break
            note("IN ", data)
            os.write(master, data)
        if master in ready:
            try:
                data = os.read(master, 65536)
            except OSError:
                break
            if not data:
                break
            note("OUT", data)
            os.write(1, data)
finally:
    termios.tcsetattr(0, termios.TCSADRAIN, saved)
    try:
        _, st = os.waitpid(pid, 0)
        status = os.waitstatus_to_exitcode(st)
    except ChildProcessError:
        pass
    note("EXIT", status)
sys.exit(status if status >= 0 else 1)
