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

# Synchronisation is done with a marker the commands print, not with the
# shell prompt.
#
# Setting PS1 and matching on it was the obvious approach and it does not
# survive a slow console.  Under emulation the m68k Goldfish TTY drops
# characters, and a line that sets PS1 is long: when half of it arrives the
# prompt never changes and the driver waits forever for a string the far
# end was never told to print.  A marker travels inside the command that is
# being run anyway, so a dropped character costs that one command instead
# of the whole session.
#
# The two halves are glued at the far end with an empty string, so the
# shell's echo of the command line reads CI-READY""-8f2arc=$? while only
# its output reads CI-READY-8f2arc=0.  That is what keeps the echo from
# being mistaken for the answer.
SENT_A = "CI-READY"
SENT_B = "8f2a"
SENTINEL = f"{SENT_A}-{SENT_B}"
MARKER = f'{SENT_A}""-{SENT_B}'
RC_RE = re.compile(re.escape(SENTINEL) + r"rc=(-?\d+)")
READY_RE = re.compile(re.escape(SENTINEL) + r"ready")


class Failure(Exception):
    pass


def log(msg):
    print(f"[boot-verify] {msg}", flush=True)


def sendline(child, text, delay):
    """Type a line, waiting for each character to come back.

    An emulated serial console is not a pipe.  The virt68k console showed
    "login: r" -- the rest of "root" gone -- at a hundredth of a second per
    character and again at six hundredths, and then echoed the next line
    with every character doubled.  A fixed delay cannot fix that, because
    the loss is not about rate: getty flushes its input while it is still
    setting the terminal up, so whatever was typed in that window is
    discarded no matter how slowly it arrived.

    So instead of guessing at a delay, wait for the far end to say it got
    each character.  Echo is on -- nothing here turns it off -- so a
    character that comes back has been read, and one that does not can be
    sent again.  A doubled echo is harmless: it is still the character we
    are waiting for.

    delay <= 0 sends the whole line at once, which is right for a console
    with a real CPU behind it.
    """
    if delay <= 0:
        child.sendline(text)
        return

    for ch in text:
        for attempt in range(3):
            child.send(ch)
            if ch in " \t":
                # Whitespace does not always come back verbatim; nothing to
                # match against, so pay the delay instead.
                time.sleep(delay)
                break
            try:
                child.expect_exact(ch, timeout=5)
                break
            except pexpect.TIMEOUT:
                if attempt == 2:
                    log(f"console never echoed {ch!r}; carrying on")
            except pexpect.EOF:
                return
    child.send("\r")
    time.sleep(max(delay, 0.2))


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
    """Log in, and keep answering whatever the console shows until a shell
    on the other end says hello.

    Not a sequence of steps, because the console does not reliably perform
    them.  getty prints "login:" before it has finished setting the
    terminal up and flushes the input queue when it does, so the first
    thing typed is often partly eaten:

      login: f2aready
      Login incorrect or refused on this terminal.
      login: echo CI-READY""-8f2aready

    The retry there arrived intact -- input works fine once the console has
    settled -- but the driver was by then waiting for a shell that had
    never been logged into, while login patiently collected its attempts as
    usernames.

    So this is a loop instead: answer a login prompt with root, answer a
    password prompt with nothing, poke a silent console with the handshake,
    and finish when the handshake comes back.  Every wrong guess costs one
    more turn around the loop rather than the run.
    """
    log("waiting for a login prompt")
    deadline = time.time() + timeout
    poked = 0

    while time.time() < deadline:
        idx = child.expect(
            [r"login: *$", r"[Pp]assword: *$", READY_RE,
             pexpect.TIMEOUT, pexpect.EOF],
            timeout=min(90, max(30, deadline - time.time())),
        )

        if idx == 2:
            break

        if idx == 4:
            raise Failure("QEMU exited before a shell was reached")

        if idx == 0:
            # The settle window.  Three seconds was not enough on virt68k;
            # the cost of being generous here is paid once.
            if delay > 0:
                time.sleep(8)
            sendline(child, "root", delay)
        elif idx == 1:
            # A root account with a password would be a packaging mistake
            # on these images, but answer the prompt rather than hang.
            sendline(child, "", delay)
            sendline(child, f"echo {MARKER}ready", delay)
        else:
            poked += 1
            log(f"console quiet; asking the shell to say hello ({poked})")
            sendline(child, f"echo {MARKER}ready", delay)
    else:
        raise Failure(
            f"no shell within {timeout}s; the last of the console is in the log"
        )

    # Widen the target's idea of the terminal.  At the default 80 columns
    # the longer check commands wrap, and the wrapped echo comes back with
    # backspaces embedded in it, which defeats the filter that drops the
    # echoed line from a command's output.  Best effort: if the characters
    # do not all arrive, the next command's marker still resynchronises.
    command(child, "stty rows 50 columns 200 2>/dev/null", 120, delay)
    log("shell is up")


def command(child, cmd, timeout, delay=0.0):
    """Run cmd, wait for its marker, return (output, exit status)."""
    sendline(child, f"{cmd}; echo {MARKER}rc=$?", delay)
    child.expect(RC_RE, timeout=timeout)
    status = int(child.match.group(1))
    raw = child.before

    # What comes back is the shell's echo of the command line, possibly
    # with a prompt in front of it, then the output.  Drop everything up to
    # and including the echo, then anything still carrying the marker.
    lines = raw.splitlines()
    tail = cmd.strip()[-40:]
    for i in range(len(lines) - 1, -1, -1):
        if lines[i].rstrip().endswith(tail) or SENT_A in lines[i]:
            lines = lines[i + 1:]
            break
    lines = [l for l in lines if SENT_A not in l]
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
