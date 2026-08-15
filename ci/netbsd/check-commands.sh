#!/bin/sh
#
# Every command the image Makefiles invoke must exist on NetBSD.
#
# This is the check that cannot be done anywhere else.  vnconfig became
# vndconfig in 7.0 and kept the old name only as an alias; resize_ffs, gpt
# and dkctl have all grown and lost options across releases.  On Linux none
# of these names exist, so the check is meaningless there.
#
# Two tiers, because the tree contains far more than image builds:
#
#   REQUIRED   the base-system commands an image build cannot proceed
#              without.  Missing means a red run.
#   everything else that the extractor finds -- soffice, fs-uae, hcopy,
#              7z -- comes from pkgsrc or from a Makefile that documents a
#              cross-build on another OS.  Missing is a warning, since no
#              build host has all of them and none of them touch an image.

set -u
. "$(dirname "$0")/../lib.sh"
cd "$CI_ROOT" || exit 1

# The commands RPI/, allwinner/, evbmips/ and friends drive a disk image
# with.  If any of these is gone, an image build stops.
REQUIRED='vnconfig vndconfig disklabel dkctl gpt fdisk
newfs newfs_msdos mount mount_msdos umount fsck resize_ffs
dump restore pax tar gunzip gzip dd ftp mkdir rm cp mv ln ls
sed awk grep sync chmod chown chgrp mknod df sysctl'

# Shell keywords and builtins the extractor cannot tell from commands.
IGNORE='if then else elif fi for do done while until case esac in
set unset export cd echo exit return read shift eval exec trap
test true false break continue local'

section "commands used by the Makefiles exist in this NetBSD"

cmds=$(mktemp)
list=$(mktemp)
seen=$(mktemp)
tracked | grep -E '(^|/)Makefile([._][A-Za-z0-9]+)?$' | grep -v '\.diff$' >"$list"

# A recipe line starts with a tab.  Take the first word of each command on
# it, splitting on the shell operators that begin a new one.
while IFS= read -r f; do
	is_vendored "$f" && continue
	awk -v F="$f" '
	# A tab-indented .if/.for/.endif is a bmake directive, not a recipe.
	/^\t[ \t]*\./	{ next }
	# A line continued from the one above is an argument list, not a
	# fresh command.
	cont		{ cont = /\\$/; next }
	/^\t/ {
		cont = /\\$/
		line = $0
		sub(/^\t[ \t@+-]*/, "", line)
		gsub(/\$\([^)]*\)/, " ", line)		# $(...) substitution
		gsub(/\$\{[^}]*\}/, " ", line)		# ${...} make variable
		# Quoted text before the operator split, so that an & or ;
		# inside a message ("Push F12 & move cursor") does not look
		# like the start of another command.
		gsub(/"[^"]*"/, " ", line)
		gsub(/'"'"'[^'"'"']*'"'"'/, " ", line)
		gsub(/`/, "\n", line)			# backtick subshell
		gsub(/[;|&()]+/, "\n", line)
		n = split(line, parts, "\n")
		for (i = 1; i <= n; i++) {
			cmd = parts[i]
			sub(/^[ \t]+/, "", cmd)
			sub(/[ \t].*$/, "", cmd)
			# Only plausible command names: no paths (those are
			# checked by existence, not by $PATH), no variables,
			# no redirections, no bare numbers.
			if (cmd !~ /^[A-Za-z_][A-Za-z0-9_.+-]*$/)
				continue
			printf "%s\t%s\t%d\n", cmd, F, FNR
		}
	}' "$f"
done <"$list" | sort -u >"$cmds"

is_required() {
	case "
$REQUIRED
" in
	*"
$1
"*)	return 0 ;;
	esac
	# The list is written with several names per line, so also match
	# space-separated.
	for w in $REQUIRED; do
		[ "$w" = "$1" ] && return 0
	done
	return 1
}

missing_optional=0
while IFS="$(printf '\t')" read -r cmd file line; do
	[ -n "${cmd:-}" ] || continue
	for w in $IGNORE; do
		[ "$w" = "$cmd" ] && continue 2
	done
	grep -qxF "$cmd" "$seen" 2>/dev/null && continue
	echo "$cmd" >>"$seen"

	if command -v "$cmd" >/dev/null 2>&1; then
		is_required "$cmd" && printf '  %-16s %s\n' "$cmd" "$(command -v "$cmd")"
	elif is_required "$cmd"; then
		fail "$file" "$line" "$cmd is missing from this NetBSD base system"
	else
		missing_optional=$((missing_optional + 1))
		warn "$file" "$line" "$cmd is not installed (pkgsrc, or another OS)"
	fi
done <"$cmds"

# The other half of the check: a name in REQUIRED that no Makefile uses any
# more is dead weight in this list, and one that exists nowhere is the
# rename we are looking for.
section "required commands present on this system"
for w in $REQUIRED; do
	if command -v "$w" >/dev/null 2>&1; then
		:
	else
		warn ci/netbsd/check-commands.sh 0 \
		    "$w is in REQUIRED but not on this NetBSD $(uname -r)"
	fi
done

note "$missing_optional non-base command(s) not installed here"
rm -f "$cmds" "$list" "$seen"
finish
