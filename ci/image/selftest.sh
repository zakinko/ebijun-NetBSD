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

# Both typing modes.  0 sends a line at once, which is what a console with
# a real CPU behind it gets; anything above 0 waits for each character to be
# echoed back, which is what the m68k console needs and is a different code
# path worth covering.
for d in 0 0.01; do
	section "boot-verify.py against a fake console (--send-delay $d)"

	out=$(python3 ci/image/boot-verify.py \
	    --checks "$WORK/checks" \
	    --boot-timeout 30 --cmd-timeout 30 --send-delay "$d" \
	    --console-log "$WORK/console-$d.log" \
	    -- "$WORK/console" 2>&1) || true

	echo "$out" | sed 's/^/  /'

	# Exactly one failure, and it has to be the negative control.
	nfail=$(echo "$out" | grep -c '^FAIL ' || true)
	if [ "$nfail" -ne 1 ]; then
		fail ci/image/boot-verify.py 0 \
		    "--send-delay $d: expected exactly 1 failure, got $nfail"
	elif ! echo "$out" | grep -q 'reallyhere.*unexpectedly matched'; then
		fail ci/image/boot-verify.py 0 \
		    "--send-delay $d: the one failure was not the absent control"
	fi

	# And every other check has to have passed, which means the login
	# was found and the outputs lined up.
	for want in ' three ' '\^exact\$' '\^alpha\$' '\^bravo\$' '\^charlie\$'; do
		echo "$out" | grep -q "ok .*$want" ||
		    fail ci/image/boot-verify.py 0 \
		        "--send-delay $d: did not pass $want"
	done
done

# --- the in-image path ---------------------------------------------------
#
# Nothing types at a virt68k console; the checks are compiled to a shell
# script, run at boot, and read off the console.  That is a second way to
# get every one of these answers wrong, so exercise it too -- here with a
# fake "QEMU" that is just the compiled script, which needs neither an
# image nor an emulator.
section "the compiled in-image script"

python3 ci/image/boot-verify.py --checks "$WORK/checks" --emit-script \
    >"$WORK/cicheck.sh"

# Running it here rather than in an image, so it must not power the machine
# off when it reaches the end.
sed -e 's|^halt -p$|exit 0|' -e 's|^sync$|:|' "$WORK/cicheck.sh" \
    >"$WORK/cicheck-local.sh"

printf '#!/bin/sh\nexec /bin/sh %s\n' "$WORK/cicheck-local.sh" >"$WORK/fakeqemu"
chmod +x "$WORK/fakeqemu"

out=$(python3 ci/image/boot-verify.py \
    --checks "$WORK/checks" --in-image \
    --boot-timeout 60 --cmd-timeout 30 \
    --console-log "$WORK/console-inimage.log" \
    -- "$WORK/fakeqemu" 2>&1) || true

echo "$out" | sed 's/^/  /'

nfail=$(echo "$out" | grep -c '^FAIL ' || true)
if [ "$nfail" -ne 1 ]; then
	fail ci/image/boot-verify.py 0 \
	    "in-image: expected exactly 1 failure, got $nfail"
elif ! echo "$out" | grep -q 'reallyhere.*unexpectedly matched'; then
	fail ci/image/boot-verify.py 0 \
	    'in-image: the one failure was not the absent negative control'
fi

# Every check has to have come back, or results are being dropped
# somewhere between the script and the reader.  Counted rather than named:
# the line numbers belong to the heredoc above and would go stale the first
# time a comment is added to it.
want=$(grep -cE '^(expect|absent|run) ' "$WORK/checks")
got=$(echo "$out" | grep -c 'got line ' || true)
[ "$got" -eq "$want" ] ||
    fail ci/image/boot-verify.py 0 \
        "in-image: $want checks compiled but $got results came back"

finish
