#!/bin/sh
#
# Parse every Makefile in the tree with bmake.
#
# These Makefiles are only ever run on NetBSD, so a typo in one is not found
# until someone sits down to build an image and the build dies partway
# through, after a multi-hundred-megabyte download.  bmake -n parses the
# whole file and expands every variable without running a single command,
# which catches the typos for free on any host.
#
# pkgsrc package Makefiles pull in ../../mk/bsd.pkg.mk and a pile of
# buildlink3.mk files that only exist inside a pkgsrc checkout.  Rather than
# skip them, we reconstruct a skeleton pkgsrc tree of empty stubs around a
# copy of the package, which is enough for bmake to parse the package's own
# syntax.

set -u
. "$(dirname "$0")/../lib.sh"
cd "$CI_ROOT" || exit 1

BMAKE=${BMAKE:-bmake}
command -v "$BMAKE" >/dev/null 2>&1 || {
	echo "$BMAKE not found; install bmake" >&2
	exit 127
}

# A pkgsrc package Makefile is one that includes bsd.pkg.mk or bsd.prefs.mk.
is_pkgsrc_makefile() {
	grep -q '^\.[ 	]*include[ 	]*"\.\./\.\./mk/bsd\.\(pkg\|prefs\)\.mk"' "$1"
}

# Build a skeleton pkgsrc tree around a copy of the package, so that bmake
# can parse the package Makefile's own syntax without a pkgsrc checkout.
# Prints the parse diagnostics, if any, on stdout.
parse_pkgsrc() {
	_dir=$(dirname "$1")
	_tmp=$2
	mkdir -p "$_tmp/stub/pkg" "$_tmp/mk"
	cp "$_dir"/Makefile* "$_dir"/*.mk "$_dir"/PLIST "$_dir"/distinfo \
	    "$_tmp/stub/pkg/" 2>/dev/null

	# Stub out every ../../ include the package asks for.
	sed -n 's|^\.[ 	]*include[ 	]*"\.\./\.\./\([^"]*\)".*|\1|p' \
	    "$_tmp/stub/pkg"/Makefile* 2>/dev/null | sort -u |
	    while IFS= read -r inc; do
		mkdir -p "$_tmp/$(dirname "$inc")"
		: >"$_tmp/$inc"
	    done

	# bsd.prefs.mk defines these before the package body reads them.
	cat >"$_tmp/mk/bsd.prefs.mk" <<-'EOF'
		OPSYS?=			NetBSD
		OS_VERSION?=		10.1
		MACHINE_ARCH?=		x86_64
		X11_TYPE?=		modular
		PKGSRC_COMPILER?=	gcc
		OBJECT_FMT?=		ELF
		EOF
	cat >"$_tmp/mk/bsd.pkg.mk" <<-'EOF'
		.include "../../mk/bsd.prefs.mk"
		all:
			@:
		EOF

	(cd "$_tmp/stub/pkg" && $BMAKE -r -n -f Makefile 2>&1 >/dev/null) |
	    sed "s|$_tmp/stub/pkg|$_dir|g"
}

section "bmake parse check"

list=$(mktemp)
tracked | grep -E '(^|/)Makefile([._][A-Za-z0-9]+)?$' | grep -v '\.diff$' >"$list"

while IFS= read -r f; do
	is_vendored "$f" && continue

	tmp=$(mktemp -d)
	if is_pkgsrc_makefile "$f"; then
		kind='pkgsrc'
		out=$(parse_pkgsrc "$f" "$tmp")
	else
		kind='plain'
		out=$(cd "$(dirname "$f")" &&
		    $BMAKE -r -n -f "$(basename "$f")" -V .CURDIR 2>&1 >/dev/null)
	fi
	rm -rf "$tmp"

	if [ -n "$out" ]; then
		printf '  %-58s PARSE ERROR\n' "$f"
		echo "$out" | while IFS= read -r l; do note "$l"; done
		fail "$f" 1 "bmake cannot parse this Makefile: $(echo "$out" | head -1)"
	else
		printf '  %-58s ok (%s)\n' "$f" "$kind"
	fi
done <"$list"

rm -f "$list"
finish
