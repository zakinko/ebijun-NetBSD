# Shared helpers for the ci/ check scripts.
#
# Every check script sources this, reports problems with fail()/warn(), and
# ends with finish().  A script that never calls fail() exits 0.
#
# Findings are emitted as GitHub Actions annotations when running under
# Actions, and as plain "file:line: message" lines otherwise, so the same
# script is useful to run by hand on a NetBSD box.

: "${CI_ROOT:=$(cd "$(dirname "$0")/../.." && pwd)}"

_fails=0
_warns=0

# fail <file> <line> <message>
fail() {
	_fails=$((_fails + 1))
	if [ -n "${GITHUB_ACTIONS-}" ]; then
		printf '::error file=%s,line=%s::%s\n' "$1" "$2" "$3"
	fi
	printf 'FAIL %s:%s: %s\n' "$1" "$2" "$3"
}

# warn <file> <line> <message>
warn() {
	_warns=$((_warns + 1))
	if [ -n "${GITHUB_ACTIONS-}" ]; then
		printf '::warning file=%s,line=%s::%s\n' "$1" "$2" "$3"
	fi
	printf 'warn %s:%s: %s\n' "$1" "$2" "$3"
}

note() { printf '     %s\n' "$*"; }

section() { printf '\n== %s\n' "$*"; }

finish() {
	printf '\n%s: %d failure(s), %d warning(s)\n' \
	    "$(basename "$0")" "$_fails" "$_warns"
	[ "$_fails" -eq 0 ]
}

# List tracked files, one per line.  Falls back to find(1) so the scripts
# still work inside a NetBSD VM that was handed a tarball rather than a
# git checkout.
tracked() {
	if [ -d "$CI_ROOT/.git" ] && command -v git >/dev/null 2>&1; then
		git -C "$CI_ROOT" ls-files
	else
		(cd "$CI_ROOT" && find . -type f | sed 's|^\./||' | sort)
	fi
}

# Files that are vendored from elsewhere: NetBSD src pull-ups, upstream
# tzdata, captured device output.  We check that they are unmodified, not
# that they meet this repository's conventions.
is_vendored() {
	case "$1" in
	pullup/*|atf-test/*|dmesg/*|Guide/*) return 0 ;;
	*) return 1 ;;
	esac
}
