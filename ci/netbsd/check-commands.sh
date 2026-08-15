#!/bin/sh
#
# Every command the image Makefiles invoke must exist on NetBSD.
#
# This is the check that cannot be done anywhere else.  A recipe line that
# says "newfs_msdos" when the installed name is "newfs_msdos" is fine; one
# that says "vndconfig" on a NetBSD 6 box is not, because the rename
# happened in 7.0.  On Linux none of these names exist and the check is
# meaningless, so it only runs inside the VM.
#
# Commands that come from pkgsrc rather than base are listed separately:
# missing ones are a warning, since not every build host has them.

set -u
. "$(dirname "$0")/../lib.sh"
cd "$CI_ROOT" || exit 1

# Provided by pkgsrc, not by the base system.
FROM_PKGSRC='unzip wget pandoc ruby ruby32 ruby33 gmake git sudo qemu nono
mkimage sphinx-build convert dtc'

# Shell built-ins and keywords that look like commands to the extractor.
IGNORE='if then else elif fi for do done while case esac in exit return
set unset export cd echo test true false : @ time'

section "commands used by the Makefiles exist in this NetBSD"

cmds=$(mktemp)
list=$(mktemp)
tracked | grep -E '(^|/)Makefile([._][A-Za-z0-9]+)?$' | grep -v '\.diff$' >"$list"

# A recipe line is one that starts with a tab.  Take the first word of each
# command in it, splitting on the shell operators that start a new command.
while IFS= read -r f; do
	is_vendored "$f" && continue
	awk -v F="$f" '
	/^\t/ {
		line = $0
		sub(/^\t[ \t@+-]*/, "", line)
		# Split on ; | && || ( ) and backticks.
		gsub(/\$\([^)]*\)/, " ", line)
		gsub(/`/, " \n ", line)
		gsub(/[;|&()]+/, "\n", line)
		n = split(line, parts, "\n")
		for (i = 1; i <= n; i++) {
			cmd = parts[i]
			sub(/^[ \t]+/, "", cmd)
			sub(/[ \t].*$/, "", cmd)
			if (cmd == "" || cmd ~ /^[#$]/ || cmd ~ /[$={}"'"'"'<>*?\[]/)
				continue
			if (cmd ~ /\//)			# absolute or relative path
				continue
			printf "%s\t%s\t%d\n", cmd, F, FNR
		}
	}' "$f"
done <"$list" | sort -u >"$cmds"

seen=$(mktemp)
while IFS="$(printf '\t')" read -r cmd file line; do
	[ -n "${cmd:-}" ] || continue
	echo "$IGNORE" | tr ' \n' '\n\n' | grep -qxF "$cmd" && continue
	grep -qxF "$cmd" "$seen" 2>/dev/null && continue
	echo "$cmd" >>"$seen"

	if command -v "$cmd" >/dev/null 2>&1; then
		printf '  %-20s %s\n' "$cmd" "$(command -v "$cmd")"
	elif echo "$FROM_PKGSRC" | tr ' \n' '\n\n' | grep -qxF "$cmd"; then
		warn "$file" "$line" "$cmd is not installed (comes from pkgsrc)"
	else
		fail "$file" "$line" "$cmd does not exist on this NetBSD"
	fi
done <"$cmds"

rm -f "$cmds" "$list" "$seen"
finish
