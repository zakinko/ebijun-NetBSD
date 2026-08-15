#!/bin/sh
#
# Feed every DISKLABEL.proto to the real disklabel -R.
#
# ci/lint/check-disklabel-proto.sh checks the arithmetic on any host; this
# checks the thing that actually matters, which is whether NetBSD's
# disklabel accepts the file and writes back what the file asked for.  It
# needs a vnd, so it only runs inside the VM.
#
# Must be run as root.

set -u
. "$(dirname "$0")/../lib.sh"
cd "$CI_ROOT" || exit 1

[ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 1; }

VND=${VND:-vnd3}
WORK=$(mktemp -d)
trap 'vnconfig -u $VND 2>/dev/null; rm -rf "$WORK"' EXIT INT TERM

section "disklabel -R accepts each DISKLABEL.proto"

list=$(mktemp)
tracked | grep 'DISKLABEL\.proto$' >"$list"

while IFS= read -r f; do
	total=$(awk '/^total sectors:/ {print $3}' "$f")
	[ -n "$total" ] || { fail "$f" 0 'no "total sectors:" line'; continue; }

	# A sparse file of exactly the size the proto describes, so that a
	# partition running off the end is rejected rather than silently
	# truncated.
	img=$WORK/disk.img
	rm -f "$img"
	dd if=/dev/zero of="$img" bs=512 count=0 seek="$total" 2>/dev/null

	vnconfig -u "$VND" 2>/dev/null
	if ! vnconfig "$VND" "$img" 2>"$WORK/err"; then
		fail "$f" 0 "vnconfig failed: $(cat "$WORK/err")"
		continue
	fi

	if out=$(disklabel -R -r "$VND" "$f" 2>&1); then
		# Read it back and diff the partition lines against the proto.
		# disklabel normalises whitespace and recomputes the cylinder
		# comments, so compare only name, size and offset.
		disklabel -r "$VND" 2>/dev/null |
		    awk '/^ *[a-p]:/ {print $1, $2, $3}' >"$WORK/got"
		awk '/^ *[a-p]:/ {print $1, $2, $3}' "$f" >"$WORK/want"
		if cmp -s "$WORK/want" "$WORK/got"; then
			printf '  %-44s ok (%s sectors)\n' "$f" "$total"
		else
			fail "$f" 0 'disklabel wrote back a different partition table'
			diff -u "$WORK/want" "$WORK/got" | while IFS= read -r l; do
				note "$l"
			done
		fi
	else
		fail "$f" 0 "disklabel -R rejected it: $(echo "$out" | head -2 | tr '\n' ' ')"
	fi
	vnconfig -u "$VND" 2>/dev/null
done <"$list"

rm -f "$list"
finish
