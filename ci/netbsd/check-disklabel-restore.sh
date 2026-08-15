#!/bin/sh
#
# Feed every DISKLABEL.proto to the real disklabel -R.
#
# ci/lint/check-disklabel-proto.sh checks the arithmetic on any host; this
# checks the thing that actually matters, which is whether NetBSD's own
# disklabel accepts the file and writes back the partitions the file asked
# for.  It is also what settles whether the stale "cylinders: 587" line
# every one of these protos carries has any consequence.
#
# disklabel treats a regular file as a disk (-F, and it is the default for
# a regular file), so this needs neither a vnd nor root.

set -u
. "$(dirname "$0")/../lib.sh"
cd "$CI_ROOT" || exit 1

command -v disklabel >/dev/null 2>&1 || {
	echo 'disklabel not found; this script is for NetBSD' >&2
	exit 127
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

section "disklabel -R accepts each DISKLABEL.proto"

list=$(mktemp)
tracked | grep 'DISKLABEL\.proto$' >"$list"

while IFS= read -r f; do
	total=$(awk '/^total sectors:/ {print $3}' "$f")
	if [ -z "$total" ]; then
		fail "$f" 0 'no "total sectors:" line'
		continue
	fi

	# A sparse file of exactly the size the proto describes, so that a
	# partition running off the end is rejected rather than silently
	# accepted.  Seeking to the last sector and writing it is what makes
	# the file that size without allocating gigabytes.
	img=$WORK/disk.img
	rm -f "$img"
	dd if=/dev/zero of="$img" bs=512 count=1 seek=$((total - 1)) \
	    >/dev/null 2>&1
	if [ "$(wc -c <"$img")" -ne $((total * 512)) ]; then
		fail "$f" 0 "could not create a $((total * 512)) byte test image"
		continue
	fi

	if out=$(disklabel -R -F "$img" "$f" 2>&1); then
		disklabel -F "$img" 2>/dev/null |
		    awk '/^ *[a-p]:/ {print $1, $2, $3}' | sort >"$WORK/got"
		awk '/^ *[a-p]:/ && $2 != 0 {print $1, $2, $3}' "$f" |
		    sort >"$WORK/want"

		# Every partition the proto asked for has to come back with
		# the same size and offset.  disklabel may add entries of its
		# own, so this is a subset test, not a diff.
		missing=$(comm -23 "$WORK/want" "$WORK/got")
		if [ -z "$missing" ]; then
			printf '  %-44s ok (%s sectors)\n' "$f" "$total"
		else
			fail "$f" 0 'disklabel wrote back different partitions'
			echo "$missing" | while IFS= read -r l; do
				note "asked for: $l"
			done
			disklabel -F "$img" 2>/dev/null |
			    awk '/^ *[a-p]:/ {print "  got:       " $1, $2, $3}'
		fi
	else
		fail "$f" 0 "disklabel -R rejected it: $(echo "$out" | head -2 | tr '\n' ' ')"
	fi
done <"$list"

rm -f "$list"
finish
