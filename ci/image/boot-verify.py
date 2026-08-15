#!/usr/bin/env python3
"""Boot an image under QEMU and check that it actually works.

Building an image that mounts on the build host proves very little: the
interesting failures -- a kernel that panics on the target, an fstab that
names a wedge the board does not create, an rc.conf line that stops
multi-user coming up -- only appear when something boots it.  This drives a
QEMU serial console and asserts against what the running system says.

The checks live in a plain text file so that adding one does not mean
touching Python:

    # wait SECONDS REGEX      -- wait for REGEX on the console
    # send TEXT               -- type TEXT and press return
    # expect REGEX :: COMMAND -- run COMMAND, require its output to match
    # absent REGEX :: COMMAND -- run COMMAND, require its output NOT to match
    # run COMMAND             -- run COMMAND, require exit status 0

Everything after the first '--' on the command line is the QEMU invocation.
"""

import argparse
import os
import re
import shlex
import sys
import time

try:
    import pexpect
except ImportError:
    sys.exit("boot-verify: pexpect is not installed (pip install pexpect)")

# A prompt we set ourselves, so that matching it can never collide with
# something the boot messages happen to contain.
#
# It is assembled from two halves at the far end because the shell echoes
# back the line that sets PS1.  If that echo contained the finished prompt
# string, the first expect() would match the echo instead of a real prompt
# and every command from then on would be read against the *previous*
# command's output.
SENT_A = "CI-READY"
SENT_B = "8f2a"
SENTINEL = f"{SENT_A}-{SENT_B}"
PROMPT = re.compile(re.escape(SENTINEL) + r"> ")
SET_PROMPT = (
    f"stty -echo 2>/dev/null; _a={SENT_A}; _b={SENT_B}; "
    'PS1="$_a-$_b> "; export PS1'
)


class Failure(Exception):
    pass


def log(msg):
    print(f"[boot-verify] {msg}", flush=True)


def sendline(child, text, delay):
    """Type a line one character at a time.

    An emulated serial console is not a pipe.  The Goldfish TTY the m68k
    kernel runs on drops characters when they arrive faster than it reads
    them, and a dropped character in the middle of "root" leaves the login
    prompt waiting while everything sent afterwards is typed into it.  A
    couple of hundredths of a second per character costs a second or two
    per command and makes the difference between a session and a mess.
    """
    if delay <= 0:
        child.sendline(text)
        return
    for ch in text:
        child.send(ch)
        time.sleep(delay)
    child.send("\r")
    time.sleep(delay)


def annotate(level, msg):
    if os.environ.get("GITHUB_ACTIONS"):
        print(f"::{level}::{msg}", flush=True)


def unquote(pattern):
    """Drop one layer of surrounding quotes from a check's pattern.

    Patterns get quoted in the check files so that leading and trailing
    spaces survive being read -- `expect ' on / '` is asking about exactly
    that, spaces included.  Without this the quote characters end up in the
    regex and are looked for in the output, which fails an `expect` loudly
    and passes an `absent` silently.  The silent half is the dangerous one.
    """
    if len(pattern) >= 2 and pattern[0] == pattern[-1] and pattern[0] in "'\"":
        return pattern[1:-1]
    return pattern


def parse_checks(path):
    steps = []
    with open(path, encoding="utf-8") as fh:
        for lineno, raw in enumerate(fh, 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            verb, _, rest = line.partition(" ")
            rest = rest.strip()
            if verb == "wait":
                secs, _, pattern = rest.partition(" ")
                steps.append(("wait", lineno, float(secs), unquote(pattern.strip())))
            elif verb == "send":
                steps.append(("send", lineno, rest))
            elif verb in ("expect", "absent"):
                pattern, sep, command = rest.partition("::")
                if not sep:
                    raise Failure(f"{path}:{lineno}: {verb} needs 'REGEX :: COMMAND'")
                pattern = unquote(pattern.strip())
                try:
                    re.compile(pattern)
                except re.error as e:
                    raise Failure(f"{path}:{lineno}: bad regex {pattern!r}: {e}")
                steps.append((verb, lineno, pattern, command.strip()))
            elif verb == "run":
                steps.append(("run", lineno, rest))
            else:
                raise Failure(f"{path}:{lineno}: unknown verb {verb!r}")
    return steps


def establish_prompt(child, timeout, delay):
    """Get from a login prompt to a shell with a prompt we recognise.

    Only "login:" and "Password:" are matched here, both anchored at the
    end of the buffer.  An earlier version also accepted a bare "#" as an
    already-root shell, which matched a hash somewhere in the boot messages
    the moment it happened to sit at the end of the buffer: the driver then
    typed its setup at a console that was still counting down to multi-user
    and never logged in at all.  From here on the only thing matched is the
    prompt we set ourselves, which cannot occur by accident.
    """
    log("waiting for a login prompt")
    idx = child.expect(
        [r"login: *$", r"[Pp]assword: *$", pexpect.TIMEOUT, pexpect.EOF],
        timeout=timeout,
    )
    if idx == 2:
        raise Failure(f"no login prompt within {timeout}s")
    if idx == 3:
        raise Failure("QEMU exited before reaching a login prompt")

    if idx == 0:
        sendline(child, "root", delay)
        # A root account with a password would be a packaging mistake on
        # these images, but tolerate one prompt rather than hang.
        j = child.expect(
            [r"[Pp]assword: *$", pexpect.TIMEOUT, pexpect.EOF], timeout=60
        )
        if j == 0:
            sendline(child, "", delay)
    else:
        sendline(child, "", delay)

    # Widen the target's idea of the terminal.  At the default 80 columns
    # the longer check commands wrap, and the wrapped echo comes back with
    # backspaces embedded in it -- which defeats the filter that drops the
    # echoed line from a command's output.
    #
    # Then quieten the shell and give it a prompt that cannot be confused
    # with console output.  Getting that prompt back is also what confirms
    # the login worked: nothing else echoes this string.
    #
    # Retried, because a character lost on the way in leaves the console
    # waiting at a prompt that will never be satisfied, and sending the
    # line again is the only way to find out.
    for attempt in range(1, 5):
        sendline(child, "stty rows 50 columns 200 2>/dev/null", delay)
        sendline(child, SET_PROMPT, delay)
        try:
            child.expect(PROMPT, timeout=60)
            break
        except pexpect.TIMEOUT:
            log(f"no prompt yet (attempt {attempt}); sending a newline and retrying")
            sendline(child, "", delay)
    else:
        raise Failure(
            "logged in but no shell prompt came back after 4 tries; "
            "the last of the console is in the log"
        )

    # Drain whatever else is queued -- the login banner, the motd, a prompt
    # printed before PS1 took effect, a late rc(8) message.  Anything left
    # in the buffer here would be read as the first check's output.
    while True:
        try:
            child.expect(PROMPT, timeout=5)
        except (pexpect.TIMEOUT, pexpect.EOF):
            break
    log("shell is up")


def command(child, cmd, timeout, delay=0.0):
    """Run cmd, return (output, exit status)."""
    sendline(child, f"{cmd}; echo {SENTINEL}rc=$?", delay)
    child.expect(PROMPT, timeout=timeout)
    raw = child.before
    m = re.search(re.escape(SENTINEL) + r"rc=(\d+)", raw)
    status = int(m.group(1)) if m else -1
    # Drop the echoed command line and the rc marker from the output.
    lines = [
        l
        for l in raw.splitlines()
        if SENTINEL not in l and l.strip() != cmd.strip()
    ]
    return "\n".join(lines).strip(), status


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--checks", required=True, help="check script to run")
    ap.add_argument("--boot-timeout", type=float, default=900.0)
    ap.add_argument("--cmd-timeout", type=float, default=180.0)
    ap.add_argument("--console-log", default="console.log")
    ap.add_argument("--send-delay", type=float, default=0.02,
                    help="seconds between characters typed at the console; "
                         "raise it for a slow emulated UART, 0 to disable")
    ap.add_argument("qemu", nargs=argparse.REMAINDER,
                    help="-- followed by the QEMU command line")
    args = ap.parse_args()

    qemu = args.qemu
    if qemu and qemu[0] == "--":
        qemu = qemu[1:]
    if not qemu:
        sys.exit("boot-verify: no QEMU command given after --")

    steps = parse_checks(args.checks)

    log("qemu: " + " ".join(shlex.quote(a) for a in qemu))
    started = time.time()
    child = pexpect.spawn(
        qemu[0], qemu[1:], encoding="utf-8", codec_errors="replace", timeout=None,
        dimensions=(40, 200),
    )
    with open(args.console_log, "w", encoding="utf-8") as console:
        child.logfile_read = console
        failures = []
        try:
            establish_prompt(child, args.boot_timeout, args.send_delay)
            log(f"reached multi-user in {time.time() - started:.0f}s")

            for step in steps:
                verb, lineno = step[0], step[1]
                if verb == "wait":
                    _, _, secs, pattern = step
                    log(f"wait {secs:g}s for /{pattern}/")
                    try:
                        child.expect(pattern, timeout=secs)
                    except pexpect.TIMEOUT:
                        failures.append(f"{args.checks}:{lineno}: "
                                        f"/{pattern}/ did not appear within {secs:g}s")
                elif verb == "send":
                    sendline(child, step[2], args.send_delay)
                elif verb == "run":
                    cmd = step[2]
                    out, rc = command(child, cmd, args.cmd_timeout, args.send_delay)
                    if rc != 0:
                        failures.append(f"{args.checks}:{lineno}: "
                                        f"`{cmd}` exited {rc}\n{out}")
                    else:
                        log(f"ok   {cmd}")
                elif verb in ("expect", "absent"):
                    _, _, pattern, cmd = step
                    out, _ = command(child, cmd, args.cmd_timeout, args.send_delay)
                    hit = re.search(pattern, out, re.MULTILINE) is not None
                    if verb == "expect" and not hit:
                        failures.append(f"{args.checks}:{lineno}: "
                                        f"`{cmd}` output did not match /{pattern}/\n{out}")
                    elif verb == "absent" and hit:
                        failures.append(f"{args.checks}:{lineno}: "
                                        f"`{cmd}` output unexpectedly matched /{pattern}/\n{out}")
                    else:
                        log(f"ok   {cmd}  ~ /{pattern}/")
        except Failure as e:
            failures.append(str(e))
        except pexpect.TIMEOUT:
            failures.append("timed out waiting for the console")
        except pexpect.EOF:
            failures.append("QEMU exited unexpectedly")
        finally:
            try:
                child.sendline("halt -p 2>/dev/null || poweroff 2>/dev/null || true")
                child.expect(pexpect.EOF, timeout=60)
            except Exception:
                pass
            child.terminate(force=True)

    log(f"console log written to {args.console_log}")
    for f in failures:
        annotate("error", f.splitlines()[0])
        print(f"FAIL {f}", file=sys.stderr)
    if failures:
        log(f"{len(failures)} check(s) failed")
        return 1
    log("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
