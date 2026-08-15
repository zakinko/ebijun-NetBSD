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
# Runs inside the NetBSD VM: it needs vnconfig, disklabel, newfs and the
# rest, which is the whole reason the VM is there.  Must be run as root.

set -eu
. "$(dirname "$0")/../lib.sh"

REL=${REL:-11.0}
MIRROR=${MIRROR:-https://cdn.netbsd.org/pub/NetBSD}
BASE=$MIRROR/NetBSD-$REL/virt68k
OUT=${OUT:-virt68k.img}
SIZE_MB=${SIZE_MB:-1536}
VND=${VND:-vnd2}
MNT=${MNT:-/mnt/ci-virt68k}

# The sets a system needs to boot multi-user and run a compiler.  Leaving
# out x*.tgz keeps the download to something a CI run can afford.
SETS=${SETS:-base.tgz etc.tgz comp.tgz kern-GENERIC.tgz modules.tgz text.tgz}

[ "$(id -u)" = 0 ] || { echo 'must run as root' >&2; exit 1; }

work=$(mktemp -d)
cleanup() {
	umount "$MNT" 2>/dev/null || true
	vnconfig -u "$VND" 2>/dev/null || true
	rm -rf "$work"
}
trap cleanup EXIT INT TERM

section "fetching NetBSD $REL/virt68k"
mkdir -p "$work/sets"
for s in $SETS; do
	note "$s"
	ftp -o "$work/sets/$s" "$BASE/binary/sets/$s"
done
ftp -o "$work/netbsd-GENERIC.gz" "$BASE/binary/kernel/netbsd-GENERIC.gz"
gunzip -f "$work/netbsd-GENERIC.gz"
cp "$work/netbsd-GENERIC" netbsd-GENERIC

section "creating a ${SIZE_MB}MB image"
rm -f "$OUT"
dd if=/dev/zero of="$OUT" bs=1m count="$SIZE_MB" 2>/dev/null

vnconfig -u "$VND" 2>/dev/null || true
vnconfig "$VND" "$OUT"

# One 4.2BSD partition covering the disk, which is what root=ld0 on the
# kernel command line resolves to.
total=$((SIZE_MB * 2048))
cat >"$work/label.proto" <<EOF
type: SCSI
disk: STORAGE DEVICE
label: netbsd-ci
flags:
bytes/sector: 512
sectors/track: 32
tracks/cylinder: 64
sectors/cylinder: 2048
cylinders: $((total / 2048))
total sectors: $total
rpm: 3600
interleave: 1

4 partitions:
#        size    offset     fstype [fsize bsize cpg/sgs]
 a: $((total - 2048))      2048     4.2BSD   1024  8192    64
 d: $total         0     unused      0     0
EOF
disklabel -R -r "$VND" "$work/label.proto"
disklabel "$VND"

newfs -O 2 "/dev/r${VND}a"

mkdir -p "$MNT"
mount "/dev/${VND}a" "$MNT"

section "extracting sets"
for s in $SETS; do
	note "$s"
	tar -xzpf "$work/sets/$s" -C "$MNT"
done

section "configuring"
# MAKEDEV lives in the etc set and has to be run against the new root, or
# the image comes up with no /dev at all.
(cd "$MNT/dev" && sh MAKEDEV all) >/dev/null 2>&1

cat >"$MNT/etc/fstab" <<'EOF'
/dev/ld0a	/	ffs	rw	1 1
ptyfs		/dev/pts	ptyfs	rw	0 0
EOF

cat >>"$MNT/etc/rc.conf" <<'EOF'
rc_configured=YES
hostname=netbsd-ci
sshd=NO
# The CI console is a serial line with nothing on the other end once the
# checks finish; a DHCP client that keeps retrying just fills the log.
dhcpcd=YES
EOF

# Root with no password: this image exists to be driven by a script over a
# serial console inside a throwaway VM, and never leaves the runner.
sed -i.bak 's|^root::|root::|' "$MNT/etc/master.passwd" 2>/dev/null || true
chroot "$MNT" /usr/sbin/pwd_mkdb -p /etc/master.passwd 2>/dev/null || true

# A getty on the virt console, so boot-verify.py has a login prompt.
grep -q '^console' "$MNT/etc/ttys" || echo 'console "/usr/libexec/getty Pc" vt100 on secure' >>"$MNT/etc/ttys"

sync
umount "$MNT"
vnconfig -u "$VND"

section "done"
ls -l "$OUT" netbsd-GENERIC
