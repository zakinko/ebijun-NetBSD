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
SENTINEL = "CI-READY-8f2a"
PROMPT = re.compile(re.escape(SENTINEL) + r"> ")


class Failure(Exception):
    pass


def log(msg):
    print(f"[boot-verify] {msg}", flush=True)


def annotate(level, msg):
    if os.environ.get("GITHUB_ACTIONS"):
        print(f"::{level}::{msg}", flush=True)


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
                steps.append(("wait", lineno, float(secs), pattern.strip()))
            elif verb == "send":
                steps.append(("send", lineno, rest))
            elif verb in ("expect", "absent"):
                pattern, sep, command = rest.partition("::")
                if not sep:
                    raise Failure(f"{path}:{lineno}: {verb} needs 'REGEX :: COMMAND'")
                steps.append((verb, lineno, pattern.strip(), command.strip()))
            elif verb == "run":
                steps.append(("run", lineno, rest))
            else:
                raise Failure(f"{path}:{lineno}: unknown verb {verb!r}")
    return steps


def establish_prompt(child, timeout):
    """Get from a login prompt to a shell with a prompt we recognise."""
    log("waiting for a login prompt")
    idx = child.expect(
        [r"login:", r"#\s*$", pexpect.TIMEOUT, pexpect.EOF], timeout=timeout
    )
    if idx == 2:
        raise Failure(f"no login prompt within {timeout}s")
    if idx == 3:
        raise Failure("QEMU exited before reaching a login prompt")
    if idx == 0:
        child.sendline("root")
        # A root account with a password would be a packaging mistake on
        # these images, but tolerate one prompt rather than hang.
        j = child.expect([r"[Pp]assword:", r"#\s*$", pexpect.TIMEOUT], timeout=120)
        if j == 0:
            child.sendline("")
            child.expect([r"#\s*$", pexpect.TIMEOUT], timeout=120)

    # Quieten the shell and give it a prompt that cannot be confused with
    # console output, then drain everything printed up to now.
    child.sendline(f"set +o emacs 2>/dev/null; PS1='{SENTINEL}> '; export PS1")
    child.sendline("")
    child.expect(PROMPT, timeout=120)
    child.expect(PROMPT, timeout=120)
    log("shell is up")


def command(child, cmd, timeout):
    """Run cmd, return (output, exit status)."""
    child.sendline(f"{cmd}; echo {SENTINEL}rc=$?")
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
            establish_prompt(child, args.boot_timeout)
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
                    child.sendline(step[2])
                elif verb == "run":
                    cmd = step[2]
                    out, rc = command(child, cmd, args.cmd_timeout)
                    if rc != 0:
                        failures.append(f"{args.checks}:{lineno}: "
                                        f"`{cmd}` exited {rc}\n{out}")
                    else:
                        log(f"ok   {cmd}")
                elif verb in ("expect", "absent"):
                    _, _, pattern, cmd = step
                    out, _ = command(child, cmd, args.cmd_timeout)
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
