#!/bin/sh
#
# Drive RPI/RPIimage/Image/aarch64/Makefile to build the image.
#
# The Makefile is not modified and not reimplemented; it is invoked with the
# two variables CI has to change (see the workflow for why) and with the
# mount points and vnd devices it expects prepared.
#
# Runs inside the NetBSD VM as root.

set -eu
. "$(dirname "$0")/../lib.sh"

REL=${REL:-10.1}
MIRROR=${MIRROR:-https://cdn.netbsd.org/pub/NetBSD}
GZIMG=$MIRROR/NetBSD-$REL/evbarm-aarch64/binary/gzimg/arm64.img.gz
IMGDIR=$CI_ROOT/RPI/RPIimage/Image/aarch64
OUT=${OUT:-netbsd-raspi-aarch64.img}

[ "$(id -u)" = 0 ] || { echo 'must run as root' >&2; exit 1; }

# The Makefile mounts on /mnt1../mnt4 and uses vnd0 and vnd1.
for d in /mnt1 /mnt2 /mnt3 /mnt4; do mkdir -p "$d"; done
for v in vnd0 vnd1; do vnconfig -u "$v" 2>/dev/null || true; done

cleanup() {
	for m in /mnt1 /mnt2 /mnt3 /mnt4; do umount "$m" 2>/dev/null || true; done
	for v in vnd0 vnd1; do vnconfig -u "$v" 2>/dev/null || true; done
}
trap cleanup EXIT INT TERM

section "fetching the $REL aarch64 gzimg"
ftp -o "$IMGDIR/arm64.img.gz" "$GZIMG"
ls -l "$IMGDIR/arm64.img.gz"

section "make file gpt restore"
# FILE is normally `date +%F`-..., which would rename the artifact daily.
# RPI normally points into NetBSD-daily, which gets deleted.
cd "$IMGDIR"
make FILE="$OUT" RPI=arm64.img.gz file
make FILE="$OUT" RPI=arm64.img.gz gpt
make FILE="$OUT" RPI=arm64.img.gz restore

section "result"
ls -l "$IMGDIR/$OUT"
vnconfig vnd0 "$IMGDIR/$OUT"
gpt show vnd0 || true
dkctl vnd0 listwedges || true
vnconfig -u vnd0

mv "$IMGDIR/$OUT" "$CI_ROOT/$OUT"
rm -f "$IMGDIR/arm64.img.gz" "$IMGDIR/a.img"
ls -l "$CI_ROOT/$OUT"
