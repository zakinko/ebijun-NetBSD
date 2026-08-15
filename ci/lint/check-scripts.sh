#!/bin/sh
#
# Syntax-check the interpreted files that ship inside the images.
#
# A broken .uim.d custom file or mikutter plugin does not stop the image
# building; it fails at first login on the board, which is the worst place
# to find out.  None of these need the interpreter they target to be the
# one on the build host -- a parse is a parse.

set -u
. "$(dirname "$0")/../lib.sh"
cd "$CI_ROOT" || exit 1

list=$(mktemp)
tracked >"$list"

section "ruby -c"
if command -v ruby >/dev/null 2>&1; then
	while IFS= read -r f; do
		case $f in
		*.rb)	;;
		*)	continue ;;
		esac
		# patch-pkg_share_mikutter_mikutter.rb is a diff that happens to
		# end in .rb; it is checked by check-pkgsrc-patches.sh instead.
		case $(basename "$f") in patch-*) continue ;; esac

		if ! out=$(ruby -c "$f" 2>&1); then
			fail "$f" 0 "$(echo "$out" | head -1)"
		else
			printf '  %-64s ok\n' "$f"
		fi
	done <"$list"
else
	note 'ruby not installed, skipped'
fi

section "YAML parses"
if command -v python3 >/dev/null 2>&1 &&
    python3 -c 'import yaml' >/dev/null 2>&1; then
	while IFS= read -r f; do
		case $f in
		*.yml|*.yaml)	;;
		*)		continue ;;
		esac
		if out=$(python3 -c '
import sys, yaml
list(yaml.safe_load_all(open(sys.argv[1], encoding="utf-8", errors="replace")))
' "$f" 2>&1); then
			printf '  %-64s ok\n' "$f"
		else
			fail "$f" 0 "$(echo "$out" | tail -1)"
		fi
	done <"$list"
else
	note 'PyYAML not installed, skipped'
fi

section "Scheme (uim custom files) balance"
# uim reads these with a Scheme reader at session start.  An unbalanced
# paren there means no input method on the built image.
while IFS= read -r f; do
	case $f in
	*.scm)	;;
	*)	continue ;;
	esac
	out=$(awk '
	{
		line = $0
		# Strip ; comments and "..." strings before counting.
		gsub(/\\./, "", line)
		gsub(/"[^"]*"/, "", line)
		sub(/;.*/, "", line)
		n = length(line)
		for (i = 1; i <= n; i++) {
			c = substr(line, i, 1)
			if (c == "(") depth++
			else if (c == ")") {
				depth--
				if (depth < 0) {
					printf "%d|more ) than ( by this line\n", FNR
					depth = 0
				}
			}
		}
	}
	END { if (depth > 0) printf "%d|%d unclosed ( at end of file\n", FNR, depth }
	' "$f")
	if [ -n "$out" ]; then
		echo "$out" >"$list.f"
		while IFS='|' read -r line msg; do
			fail "$f" "$line" "$msg"
		done <"$list.f"
		rm -f "$list.f"
	fi
done <"$list"

section "XPM icons are well-formed"
# The icewm themes carry 482 of these; a truncated one makes icewm exit at
# startup rather than draw a broken icon.
while IFS= read -r f; do
	case $f in
	*.xpm)	;;
	*)	continue ;;
	esac
	if ! grep -q 'XPM' "$f" 2>/dev/null; then
		fail "$f" 1 'no /* XPM */ marker'
		continue
	fi
	awk '
	/^static char/ { instr = 1; next }
	instr && /^"/  { rows++ }
	instr && /^};/ { exit }
	END {
		if (rows == 0) print "no pixel rows found"
	}' "$f" | while IFS= read -r m; do
		[ -n "$m" ] && fail "$f" 0 "$m"
	done
done <"$list"

rm -f "$list"
finish
