#!/bin/sh
#
# Build a bootable NetBSD/virt68k disk image, the way virt68k/Makefile does
# it but with the pieces CI can actually fetch.
#
# virt68k/Makefile points at a pinned NetBSD-daily timestamp, and daily
# builds are deleted after a few weeks, so a workflow that used it would go
# red on its own without anybody touching the repository.  We take the same
# sets from the 11.0 release directory instead, which does not move.
#
# The image is built with makefs rather than by newfs'ing a vnd, because
# the build host is amd64 and the target is m68k.  Two things go wrong the
# other way:
#
#   - a disklabel written by the host lands at the host's LABELSECTOR and
#     LABELOFFSET, which are not the m68k ones.  The guest kernel does not
#     find it, falls back to a default label where partition a starts at
#     sector 0, looks for a filesystem there, and halts with "cannot mount
#     root, error = 79" while the real filesystem sits a megabyte in.
#   - FFS is byte-order sensitive, and m68k is big-endian.
#
# makefs takes -B for the second and needs no label at all for the first:
# the image is one filesystem filling the disk, which is what the guest's
# default label describes anyway, and what the liveimages virt68k/Boot
# expects are.
#
# Runs inside the NetBSD VM: MAKEDEV has to create device nodes.  Must be
# run as root.

set -eu
. "$(dirname "$0")/../lib.sh"

REL=${REL:-11.0}
MIRROR=${MIRROR:-https://cdn.netbsd.org/pub/NetBSD}
BASE=$MIRROR/NetBSD-$REL/virt68k
OUT=${OUT:-virt68k.img}
# Compiled by boot-verify.py --emit-script on the Linux side, because
# the NetBSD VM has no Python.
CHECKS_SCRIPT=${CHECKS_SCRIPT:-$CI_ROOT/cicheck.sh}
SIZE_MB=${SIZE_MB:-1536}

# m68k. If this script is ever pointed at another port, this and the sets
# are the two things to change.
ENDIAN=${ENDIAN:-be}

# The sets a system needs to boot multi-user and run a compiler.  Leaving
# out x*.tgz keeps the download to something a CI run can afford.
SETS=${SETS:-base.tgz etc.tgz comp.tgz kern-GENERIC.tgz modules.tgz text.tgz}

[ "$(id -u)" = 0 ] || { echo 'must run as root' >&2; exit 1; }
command -v makefs >/dev/null 2>&1 || { echo 'makefs not found' >&2; exit 1; }

# /var/tmp, not /tmp: NetBSD mounts /tmp as tmpfs sized from RAM and the
# staging tree is well over a gigabyte.
work=$(mktemp -d /var/tmp/ci-virt68k.XXXXXX)
root=$work/root
trap 'rm -rf "$work"' EXIT INT TERM

section "fetching NetBSD $REL/virt68k"
mkdir -p "$work/sets" "$root"
for s in $SETS; do
	note "$s"
	ftp -o "$work/sets/$s" "$BASE/binary/sets/$s"
done
ftp -o "$work/netbsd-GENERIC.gz" "$BASE/binary/kernel/netbsd-GENERIC.gz"
gunzip -f "$work/netbsd-GENERIC.gz"
cp "$work/netbsd-GENERIC" netbsd-GENERIC

section "extracting sets"
for s in $SETS; do
	note "$s"
	tar -xzpf "$work/sets/$s" -C "$root"
done

section "configuring"
# MAKEDEV comes from the m68k etc set and has the m68k device numbers baked
# into it, so running it here on amd64 still produces the right nodes.
(cd "$root/dev" && sh MAKEDEV all)

# One filesystem filling the disk, so this must match the default label the
# guest falls back to.
cat >"$root/etc/fstab" <<'EOF'
/dev/ld0a	/		ffs	rw	1 1
ptyfs		/dev/pts	ptyfs	rw	0 0
EOF

cat >>"$root/etc/rc.conf" <<'EOF'
rc_configured=YES
hostname=netbsd-ci
sshd=NO
dhcpcd=YES
# There is no swap partition -- the image is one filesystem filling the
# disk -- so savecore has nothing to look at and only prints an error.
savecore=NO
EOF

# Nothing logs in to this image.  Driving a console by typing at it works
# on a port QEMU can accelerate and does not work on one it interprets: the
# Goldfish TTY discarded whatever was typed in the window after getty
# printed its prompt, echoed nothing back to say so, and left login
# collecting the retries as usernames until it timed out.
#
# So the checks are compiled to a shell script on the Linux side, installed
# here, and run at boot from rc.local.  The console is read, never written,
# and /etc/ttys is left as it ships -- with the console getty off, which is
# one less thing writing to the line.
if [ -f "$CHECKS_SCRIPT" ]; then
	# Syntax-check it before it goes in.  This file is generated, and a
	# generated file that is broken installs just as quietly as a good
	# one: the image would boot, rc.local would die on the first parse
	# error, no results would ever reach the console, and the failure
	# would read as "the image never answered" rather than "the script
	# was malformed".
	if ! sh -n "$CHECKS_SCRIPT"; then
		echo "$CHECKS_SCRIPT does not parse; refusing to install it" >&2
		exit 1
	fi
	cp "$CHECKS_SCRIPT" "$root/root/cicheck.sh"
	chmod 755 "$root/root/cicheck.sh"
	printf '\nsh /root/cicheck.sh\n' >>"$root/etc/rc.local"
	note "installed $(wc -l <"$CHECKS_SCRIPT") lines of checks as /root/cicheck.sh"
else
	note "no $CHECKS_SCRIPT; the image will boot but check nothing"
fi

# root already has an empty password in the etc set, and pwd.db and spwd.db
# ship alongside it.  Editing master.passwd here would mean rebuilding
# those, and pwd_mkdb cannot run against this root: its binaries are m68k.

section "makefs -t ffs -B $ENDIAN -s ${SIZE_MB}m"
rm -f "$OUT"
makefs -t ffs -B "$ENDIAN" -s "${SIZE_MB}m" \
    -o version=2,bsize=16384,fsize=2048 \
    "$OUT" "$root"

section "done"
ls -l "$OUT" netbsd-GENERIC
file "$OUT" 2>/dev/null || true
