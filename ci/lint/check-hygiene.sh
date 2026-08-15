#!/bin/sh
#
# Repository hygiene.
#
# The thing this exists to catch is an editor silently transcoding a file.
# Several trees here hold Japanese text, and a round trip through an editor
# that guesses the encoding rewrites every line of the file, burying the one
# line that was meant to change.  Recording which files are not UTF-8 and
# failing when that set changes turns a silent 46-line diff into a red CI
# run.
#
# The rest is the usual: broken symlinks, stray CRLF, and binaries large
# enough that they should have been a release asset.

set -u
. "$(dirname "$0")/../lib.sh"
cd "$CI_ROOT" || exit 1

# Files that are legitimately not UTF-8.  Both are captured device output,
# committed verbatim as evidence; re-encoding them would falsify the record.
#   atf-test/hpcsh/HPW-50PA        ATF run with Shift_JIS test strings
#   dmesg/riscv/StarFive_...       console capture with a stray high byte
NON_UTF8_ALLOWED='atf-test/hpcsh/HPW-50PA
dmesg/riscv/StarFive_VisionFive_V2'

MAX_MB=8

list=$(mktemp)
tracked >"$list"

section "text files must be UTF-8"
# One Python pass over the whole tree: macOS iconv rejects codepoints that
# are perfectly valid UTF-8, so it is not usable as the oracle here.
bad=$(mktemp)
python3 - "$list" >"$bad" <<'PY'
import sys
for name in open(sys.argv[1], encoding='utf-8').read().split('\n'):
    if not name:
        continue
    try:
        data = open(name, 'rb').read()
    except (IsADirectoryError, FileNotFoundError, PermissionError):
        continue
    if b'\0' in data[:8192]:          # binary
        continue
    try:
        data.decode('utf-8')
    except UnicodeDecodeError as e:
        print('%s\t%d\t%#04x' % (name, data[:e.start].count(b'\n') + 1, data[e.start]))
PY
while IFS="$(printf '\t')" read -r f line byte; do
	[ -n "${f:-}" ] || continue
	if echo "$NON_UTF8_ALLOWED" | grep -qxF "$f"; then
		note "allowed non-UTF-8: $f (byte $byte at line $line)"
	else
		fail "$f" "$line" "not valid UTF-8 (byte $byte) -- did an editor transcode it?"
	fi
done <"$bad"
rm -f "$bad"

section "symlinks must resolve"
while IFS= read -r f; do
	[ -L "$f" ] || continue
	[ -e "$f" ] || fail "$f" 0 "dangling symlink -> $(readlink "$f")"
done <"$list"

section "no CRLF in files this repository owns"
while IFS= read -r f; do
	[ -f "$f" ] || continue
	is_vendored "$f" && continue
	case $f in
	*/patch-*|patch-*)	continue ;;	# handled by check-pkgsrc-patches.sh
	*.xpm|*.pcf|*.png|*.pdf|*.odp|*.ods|*.fd|*.img|*.gz|*.tar|*.zip) continue ;;
	esac
	LC_ALL=C head -c 8192 "$f" 2>/dev/null | LC_ALL=C grep -q "$(printf '\000')" && continue
	if LC_ALL=C grep -q "$(printf '\r')$" "$f" 2>/dev/null; then
		warn "$f" 0 'has CRLF line endings'
	fi
done <"$list"

section "no oversized files"
while IFS= read -r f; do
	[ -f "$f" ] || continue
	sz=$(wc -c <"$f" | tr -d ' ')
	if [ "$sz" -gt $((MAX_MB * 1024 * 1024)) ]; then
		warn "$f" 0 "$((sz / 1024 / 1024))MB -- consider a release asset instead of git"
	fi
done <"$list"

section "shell scripts parse"
# The helper scripts beside the image Makefiles (RPI, 03_back, Copy, ...)
# carry no #! line -- NetBSD hands those to /bin/sh -- so they are found by
# the executable bit rather than by extension.
while IFS= read -r f; do
	[ -f "$f" ] || continue
	is_vendored "$f" && continue
	case $f in
	*.sh)	;;
	*)	[ -x "$f" ] || continue
		case $(head -1 "$f") in
		'#!'*sh|'#!'*sh\ *)	;;
		'#!'*)	continue ;;	# ruby, perl, ... checked elsewhere
		*)	# No #!.  Only treat it as sh if it is text.
			LC_ALL=C head -c 8192 "$f" | LC_ALL=C grep -q "$(printf '\000')" &&
			    continue ;;
		esac ;;
	esac

	if ! out=$(sh -n "$f" 2>&1); then
		fail "$f" 0 "sh -n: $(echo "$out" | head -1)"
	fi
done <"$list"

rm -f "$list"
finish
