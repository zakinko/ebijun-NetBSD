#!/bin/sh
#
# Sanity-check the DISKLABEL.proto files fed to disklabel -R.
#
# A proto file that describes overlapping partitions, or one that runs off
# the end of the image, produces a disk that mounts fine on the build host
# and then corrupts itself on the target board.  disklabel -R itself is
# forgiving about a good deal of this, so check the arithmetic here rather
# than wait for the hardware to notice.
#
# Written in awk so it also runs unchanged inside the NetBSD VM, which has
# no Python in the base system.

set -u
. "$(dirname "$0")/../lib.sh"
cd "$CI_ROOT" || exit 1

section "DISKLABEL.proto geometry and partition layout"

list=$(mktemp)
findings=$(mktemp)
tracked | grep 'DISKLABEL\.proto$' >"$list"

while IFS= read -r f; do
	printf '  %-44s\n' "$f"
	out=$(awk -v FNAME="$f" '
	/^bytes\/sector:/		{ secsize   = $2 }
	/^sectors\/track:/		{ nsectors  = $2 }
	/^tracks\/cylinder:/		{ ntracks   = $2 }
	/^sectors\/cylinder:/		{ secpercyl = $2 }
	/^cylinders:/			{ ncyl      = $2 }
	/^total sectors:/		{ total     = $3 }
	/^[0-9]+ partitions:/		{ declared  = $1; inparts = 1; next }

	# " a:   4456448    458752     4.2BSD  ..."
	inparts && /^ *[a-p]:/ {
		name = $1; sub(":", "", name)
		size = $2 + 0; off = $3 + 0; type = $4
		n++
		pname[n] = name; psize[n] = size; poff[n] = off; ptype[n] = type
		pline[n] = FNR
	}

	END {
		if (secsize == 0) {
			printf "ERR|%d|no \"bytes/sector:\" line; is this a disklabel proto?\n", 1
			exit
		}
		if (nsectors * ntracks != secpercyl)
			printf "ERR|%d|sectors/cylinder is %d but sectors/track * tracks/cylinder is %d\n", \
			    0, secpercyl, nsectors * ntracks

		# The cylinder count is advisory once total sectors is set, but a
		# stale one means the "# (Cyl. x - y)" comments lie.
		if (secpercyl > 0 && ncyl * secpercyl != total)
			printf "WARN|%d|cylinders: %d * sectors/cylinder %d = %d, but total sectors is %d (should be %d)\n", \
			    0, ncyl, secpercyl, ncyl * secpercyl, total, \
			    int((total + secpercyl - 1) / secpercyl)

		if (declared != "" && n > declared)
			printf "ERR|%d|header says %s partitions but %d are listed\n", 0, declared, n

		for (i = 1; i <= n; i++) {
			if (psize[i] == 0) continue
			end = poff[i] + psize[i]
			if (end > total)
				printf "ERR|%d|partition %s ends at %d, past the end of the %d sector image\n", \
				    pline[i], pname[i], end, total

			# d is the whole disk on these ports and c is the NetBSD
			# portion; both are expected to span other partitions.
			if (pname[i] == "c" || pname[i] == "d") continue

			for (j = i + 1; j <= n; j++) {
				if (psize[j] == 0) continue
				if (pname[j] == "c" || pname[j] == "d") continue
				if (poff[i] < poff[j] + psize[j] && poff[j] < end)
					printf "ERR|%d|partitions %s and %s overlap\n", \
					    pline[i], pname[i], pname[j]
			}
		}

		# d, where present, must cover the whole image or the board will
		# not see the space it was given.
		for (i = 1; i <= n; i++)
			if (pname[i] == "d" && (poff[i] != 0 || psize[i] != total))
				printf "ERR|%d|partition d is %d sectors at %d; expected %d at 0 (whole disk)\n", \
				    pline[i], psize[i], poff[i], total
	}' "$f")

	[ -z "$out" ] && continue
	printf '%s\n' "$out" >"$findings"
	while IFS='|' read -r kind line msg; do
		case $kind in
		ERR)  fail "$f" "$line" "$msg" ;;
		WARN) warn "$f" "$line" "$msg" ;;
		esac
	done <"$findings"
done <"$list"

rm -f "$list" "$findings"
finish
