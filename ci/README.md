# ci/

Checks for the image build Makefiles, the pkgsrc patches and the files that
ship inside the images.

Nothing here needs GitHub.  Every script is `sh` plus `awk`, takes no
arguments and can be run from a checkout:

    sh ci/lint/check-makefiles.sh

They print `file:line: message` and exit non-zero if anything failed, and
add GitHub annotations when `GITHUB_ACTIONS` is set.

## What runs where, and why

The split is entirely about what a check needs in order to mean anything.

### `ci/lint/` — any host, every push

| script | what it catches |
| --- | --- |
| `check-makefiles.sh` | a Makefile bmake cannot parse.  pkgsrc package Makefiles get a skeleton pkgsrc tree of stubs built around them so they can be parsed too |
| `check-disklabel-proto.sh` | partitions that overlap or run off the end of the image; geometry that contradicts itself |
| `check-pkgsrc-patches.sh` | a missing `$NetBSD$`, a CR where patch(1) will trip on it, a `@@` header whose line counts do not match the hunk under it |
| `check-patch-applies.sh` | the same class, but proved with the real `patch(1)`: the pre-patch text is reconstructed from the diff's own context and `-` lines, so no distfile and no network are needed |
| `check-hygiene.sh` | a file that stopped being UTF-8, a dangling symlink, stray CRLF, a shell script that no longer parses |
| `check-scripts.sh` | ruby, YAML, uim Scheme and XPM files that will fail at first login on the board rather than at build time |

`check-patch-applies.sh` cannot tell you a patch still matches a *newer*
upstream.  Only a real pkgsrc build does that.

### `ci/netbsd/` — inside a NetBSD VM

| script | what it catches |
| --- | --- |
| `check-commands.sh` | a command the Makefiles call that this NetBSD does not have.  Run against 10.1 and 11.0, which is how a rename between releases gets noticed |
| `check-disklabel-restore.sh` | a proto file the real `disklabel -R` will not accept, or accepts and writes back differently |

### `ci/image/` — build, then boot

`build-virt68k.sh` and `build-rpi-aarch64.sh` run in the VM and produce an
image; `boot-verify.py` then runs on the Linux host and drives it under
QEMU over the serial console.

`build-rpi-aarch64.sh` invokes `RPI/RPIimage/Image/aarch64/Makefile`
unmodified, overriding only `RPI=` and `FILE=`.  A workflow that
reimplemented the build would go green while the Makefile people actually
run stayed broken.

## Adding a boot check

`ci/image/checks/*.txt`, one verb per line:

    wait 300 sshd
    send  root
    expect ^aarch64      :: uname -p
    absent panic         :: dmesg | grep -i panic
    run                     test -s /etc/rc.conf

`common.txt` is concatenated ahead of the per-port file, so keep device
names and architectures out of it.

## Known warnings

These are warnings rather than failures on purpose, and each one has been
run down rather than left as a maybe.

**`cylinders: 587` in every `DISKLABEL.proto`.**  The line was copied
forward from an older, smaller label and contradicts the file's own `total
sectors:` — 587 cylinders of 2048 sectors is 1202176, not the 3813376 the
same file goes on to claim.  `ci/netbsd/check-disklabel-restore.sh` settles
it: the real `disklabel -R` accepts all ten on both 10.1 and 11.0 and reads
the partitions back unchanged, because it takes its sizes from `total
sectors:`.  The only thing the stale count affects is the `# (Cyl. x - y)`
comments, which are already wrong.  Left alone; the warning stays so that a
proto with genuinely inconsistent geometry still stands out.

**Eleven commands "not installed".**  `soffice`, `fs-uae`, `hcopy`,
`hformat`, `pkg_chk`, `ruby200`, `7z` and friends come from pkgsrc, and
`apt-get` appears in `sunxi/u-boot/Makefile` because that target documents
a cross-build on Linux.  None of them touch an image build, and no build
host has all of them, so `check-commands.sh` warns for anything outside its
`REQUIRED` list and fails only for the base-system commands an image build
cannot proceed without.

**Nine pkgsrc patches with no comment.**  pkglint wants a sentence saying
why each patch exists, above the diff and below the `$NetBSD$` line.  Nine
have none.  Adding one means knowing what the patch was for, which is not
something CI can invent.
