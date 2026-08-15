#!/bin/sh
#
# Test boot-verify.py against a fake console.
#
# The driver has had three bugs that a booted image could not distinguish
# from a broken image, and each one cost a full build-and-boot run to find:
#
#   - the echo of the line that set PS1 was matched as a prompt, so every
#     command was read against the previous command's output
#   - a bare "#" in the boot messages was matched as an already-root shell,
#     so the driver typed its setup at a console still counting down to
#     multi-user and never logged in
#   - a check's pattern kept its surrounding quotes, which made `expect`
#     fail loudly and `absent` pass silently
#
# All three are visible in ten seconds against a shell script pretending to
# be a NetBSD console, so that is what this does.  It needs no QEMU and no
# image, and runs with the rest of the fast checks.

set -u
. "$(dirname "$0")/../lib.sh"
cd "$CI_ROOT" || exit 1

command -v python3 >/dev/null 2>&1 || { echo 'python3 required' >&2; exit 127; }
python3 -c 'import pexpect' 2>/dev/null || {
	echo 'pexpect not installed, skipped' >&2
	exit 0
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

# A console that prints boot noise ending in a stray '#' -- the thing that
# used to be mistaken for a root shell -- before offering a login prompt.
cat >"$WORK/console" <<'EOF'
#!/bin/sh
echo "[   1.000000] root file system type: ffs"
echo "Starting local daemons: sh -c #"
sleep 1
printf '\nNetBSD/evbarm (ci) (constty)\n\nlogin: '
read -r user
printf 'Password:'
read -r pw
echo
PS1='$ ' exec /bin/sh -i
EOF
chmod +x "$WORK/console"

# Checks chosen so that a driver with any of the three bugs gets a
# different answer than a correct one.
cat >"$WORK/checks" <<'EOF'
# Quoted patterns must lose their quotes and keep their spaces.
expect ' three '            :: echo "a three b"
expect '^exact$'            :: echo exact
# Three in a row: with the outputs shifted by one, at least one of these
# is read against the wrong command.
expect ^alpha$              :: echo alpha
expect ^bravo$              :: echo bravo
expect ^charlie$            :: echo charlie
# absent has to pass when the string is missing...
absent 'shouldnotbethere'   :: echo clean
# ...and the negative control below has to fail, or absent is vacuous.
absent 'reallyhere'         :: echo reallyhere
run                            true
EOF

section "boot-verify.py against a fake console"

out=$(python3 ci/image/boot-verify.py \
    --checks "$WORK/checks" \
    --boot-timeout 30 --cmd-timeout 30 \
    --console-log "$WORK/console.log" \
    -- "$WORK/console" 2>&1) || true

echo "$out" | sed 's/^/  /'

# Exactly one failure, and it has to be the negative control on line 13.
nfail=$(echo "$out" | grep -c '^FAIL ' || true)
if [ "$nfail" -ne 1 ]; then
	fail ci/image/boot-verify.py 0 \
	    "expected exactly 1 failure from the self-test, got $nfail"
elif ! echo "$out" | grep -q 'reallyhere.*unexpectedly matched'; then
	fail ci/image/boot-verify.py 0 \
	    'the one failure was not the absent negative control'
fi

# And every other check has to have passed, which means the login was
# found and the outputs lined up.
for want in ' three ' '\^exact\$' '\^alpha\$' '\^bravo\$' '\^charlie\$'; do
	echo "$out" | grep -q "ok .*$want" ||
	    fail ci/image/boot-verify.py 0 "self-test did not pass $want"
done

finish
