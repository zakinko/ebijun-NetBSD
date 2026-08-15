#!/bin/sh
#
# Prove each pkgsrc patch is applicable, without fetching any distfile.
#
# A unified diff carries its own "before" text: the context lines and the
# '-' lines are, together, exactly the region of the original file the patch
# expects.  Reconstructing that region and running patch(1) against it is
# enough to catch every patch that has been hand-edited into a state where
# patch will refuse it -- which is the failure this repository has actually
# hit -- and it needs neither the upstream tarball nor a network.
#
# It cannot tell you the patch still matches a *newer* upstream.  Only a
# real build does that.

set -u
. "$(dirname "$0")/../lib.sh"
cd "$CI_ROOT" || exit 1

command -v python3 >/dev/null 2>&1 || { echo 'python3 required' >&2; exit 127; }

section "each patch applies to the text it says it expects"

list=$(mktemp)
tracked | grep -E '(^|/)patch-[^/]*$' >"$list"

while IFS= read -r f; do
	work=$(mktemp -d)

	# Rebuild the pre-patch file from the patch's own old-side lines,
	# padded with filler up to the line number the first hunk names.
	target=$(python3 - "$CI_ROOT/$f" "$work" <<'PY'
import os, re, sys
patch, work = sys.argv[1], sys.argv[2]
# newline='' matters: universal-newline translation would strip the CR from
# a CRLF patch and the reconstructed file would then not match its own
# context lines.
with open(patch, encoding='utf-8', errors='surrogateescape', newline='') as fh:
    lines = fh.read().split('\n')
# split() leaves an empty element after the file's final newline.  Counting
# it as a context line adds a line the hunk does not have, which is enough
# to hide a hunk header whose count is one too high.
if lines and lines[-1] == '':
    lines.pop()

name = None
for l in lines:
    if l.startswith('--- '):
        name = l[4:].split('\t')[0].strip().rstrip('\r')
        break
if name is None:
    sys.exit(0)
if name == '/dev/null':
    # The patch creates a new file; there is nothing to reconstruct.
    print('')
    sys.exit(0)
name = re.sub(r'\.orig$', '', name)
# The header may name an absolute path (/usr/pkg/share/...); keep it inside
# the scratch directory.
name = re.sub(r'^(\.\./|/)+', '', name)
if not name:
    sys.exit(0)

# Rebuild the file hunk by hunk, padding the gaps between them so that the
# line numbers in every @@ header land where the header says they do.  A
# patch with more than one hunk is otherwise reconstructed too short and
# patch(1) reports a spurious "No such line".
out, seen_hunk = [], False
i = 0
while i < len(lines):
    m = re.match(r'@@ -(\d+)(?:,(\d+))? \+', lines[i])
    if not m:
        i += 1
        continue
    seen_hunk = True
    start = int(m.group(1))
    while len(out) < start - 1:
        out.append('/* ci filler */')
    i += 1
    while i < len(lines):
        l = lines[i]
        if l.startswith('@@ ') or l.startswith('--- '):
            break
        if l.startswith('-') or l.startswith(' '):
            out.append(l[1:])
        elif l == '':
            out.append('')
        elif l.startswith('\\') or l.startswith('+'):
            pass
        else:
            break
        i += 1

if not seen_hunk:
    sys.exit(0)

# Some upstreams -- bm2's, for one -- are CRLF throughout, so the context
# lines carry a CR.  The filler has to match or patch(1) sees a mismatch on
# the very first line it compares.
if any(l.endswith('\r') for l in out):
    out = [l if l.endswith('\r') else l + '\r' for l in out]

path = os.path.join(work, name)
os.makedirs(os.path.dirname(path) or '.', exist_ok=True)
with open(path, 'w', encoding='utf-8', errors='surrogateescape', newline='') as fh:
    fh.write('\n'.join(out) + '\n')
print(name)
PY
)

	case $target in
	'')	# Either no "---" header at all, or the patch creates a new
		# file, in which case there is nothing to apply it to.
		if grep -q '^--- /dev/null' "$f"; then
			printf '  %-70s ok (creates a new file)\n' "$f"
		else
			warn "$f" 1 'no "---" header; cannot reconstruct a target'
		fi
		rm -rf "$work"
		continue ;;
	esac

	# Name the target explicitly rather than letting patch resolve the
	# path in the header: some of these patch an installed file under
	# /usr/pkg, which no -p level reaches.
	if out=$(patch --dry-run -f "$work/$target" "$CI_ROOT/$f" 2>&1); then
		case $out in
		*'No such line'*|*'misordered'*|*'malformed'*|*'garbage'*)
			fail "$f" 0 "patch(1) complained: $(echo "$out" | grep -vi '^patching' | head -1)" ;;
		*)
			printf '  %-70s ok\n' "$f" ;;
		esac
	else
		fail "$f" 0 "patch --dry-run failed: $(echo "$out" | grep -vi '^patching' | head -2 | tr '\n' ' ')"
	fi
	rm -rf "$work"
done <"$list"

rm -f "$list"
finish
