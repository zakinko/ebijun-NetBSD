#!/bin/sh
#
# Check the pkgsrc patch files.
#
# These get hand-edited when a package is rolled forward, and a patch whose
# @@ hunk header no longer matches the lines under it is rejected by
# patch(1) only when someone next builds the package -- often months later,
# on someone else's machine.  Counting the hunk lines here catches it at
# commit time.
#
# The pkgsrc guide also wants an RCS Id on the first line and a comment
# saying why the patch exists; pkglint refuses a patch without them.

set -u
. "$(dirname "$0")/../lib.sh"
cd "$CI_ROOT" || exit 1

section "pkgsrc patch files"

list=$(mktemp)
findings=$(mktemp)
tracked | grep -E '(^|/)patch-[^/]*$' >"$list"

while IFS= read -r f; do
	printf '  %-70s\n' "$f"

	# 1 and 2 are pkgsrc conventions, so they apply to patches destined
	# for pkgsrc.  luna68k/4.4BSD/patch-vm_ram.cpp is a patch against a
	# 4.4BSD tree and is none of pkglint's business.
	case $f in
	pkgsrc/*)
		# RCS Id on the first line.
		case $(head -1 "$f") in
		'$NetBSD'*) ;;
		*) fail "$f" 1 'first line must be the $NetBSD$ RCS Id (pkgsrc guide 11.3)' ;;
		esac

		# A comment between the Id and the first ---, explaining why.
		if ! awk 'NR>1 && /^--- /{exit} NR>2 && NF{found=1} END{exit !found}' "$f"; then
			warn "$f" 3 'no comment explaining why this patch exists; pkglint wants one'
		fi ;;
	esac

	# 3. Trailing newline.  patch(1) silently drops a final hunk line that
	#    is not newline-terminated.
	if [ -n "$(tail -c 1 "$f")" ]; then
		fail "$f" 0 'file does not end with a newline'
	fi

	# 4. CRLF.  A CR on a context or +/- line is legitimate -- bm2's
	#    upstream sources are CRLF throughout, and stripping it would
	#    stop the patch matching.  A CR on the RCS Id, the comment or a
	#    ---/+++/@@ header is not: patch(1) parses those itself.
	awk '
	/^(--- |\+\+\+ |@@ )/	{ if (/\r$/) printf "ERR|%d|CR at end of patch header line\n", FNR; body = 1; next }
	!body && /\r$/		{ printf "ERR|%d|CR at end of line above the diff\n", FNR }
	' "$f" >"$findings"
	while IFS='|' read -r kind line msg; do
		[ -n "${kind:-}" ] && fail "$f" "$line" "$msg"
	done <"$findings"

	# 5. Hunk arithmetic.
	awk '
	function flush(   ) {
		if (!inhunk) return
		if (oldseen != oldcount)
			printf "ERR|%d|hunk @@ -%d,%d says %d old lines but %d are present\n", \
			    hunkline, oldstart, oldcount, oldcount, oldseen
		if (newseen != newcount)
			printf "ERR|%d|hunk @@ +%d,%d says %d new lines but %d are present\n", \
			    hunkline, newstart, newcount, newcount, newseen
		inhunk = 0
	}
	/^--- /	{ flush(); minus++; next }
	/^\+\+\+ /	{ plus++;  next }
	/^@@ / {
		flush()
		# @@ -old[,count] +new[,count] @@
		if (match($0, /-[0-9]+(,[0-9]+)?/)) {
			s = substr($0, RSTART + 1, RLENGTH - 1)
			n = index(s, ",")
			oldstart = (n ? substr(s, 1, n - 1) : s) + 0
			oldcount = (n ? substr(s, n + 1) : 1) + 0
		}
		if (match($0, /\+[0-9]+(,[0-9]+)?/)) {
			s = substr($0, RSTART + 1, RLENGTH - 1)
			n = index(s, ",")
			newstart = (n ? substr(s, 1, n - 1) : s) + 0
			newcount = (n ? substr(s, n + 1) : 1) + 0
		}
		inhunk = 1; oldseen = 0; newseen = 0; hunkline = FNR
		hunks++
		next
	}
	inhunk {
		c = substr($0, 1, 1)
		if (c == "-")		{ oldseen++ }
		else if (c == "+")	{ newseen++ }
		else if (c == "\\")	{ }		# \ No newline at end of file
		else if (c == " " || $0 == "") { oldseen++; newseen++ }
		else			{ flush() }	# trailing prose after the diff
		next
	}
	END {
		flush()
		if (hunks == 0)
			printf "ERR|%d|no @@ hunks found; this is not a unified diff\n", 1
		if (minus != plus)
			printf "ERR|%d|%d \"---\" headers but %d \"+++\" headers\n", 1, minus, plus
	}' "$f" >"$findings"

	while IFS='|' read -r kind line msg; do
		[ -z "${kind:-}" ] && continue
		case $kind in
		ERR)  fail "$f" "$line" "$msg" ;;
		WARN) warn "$f" "$line" "$msg" ;;
		esac
	done <"$findings"
done <"$list"

rm -f "$list" "$findings"
finish
