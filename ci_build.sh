#!/usr/bin/env bash
# =============================================================================
#  ci_build.sh -- build coreboot for HP ProBook 4430s.
#
#  Runs on GitHub Actions (ubuntu-latest) and also locally on any Linux box.
#  It clones coreboot, deploys the 4430s board (the port's complete
#  src/mainboard/hp/snb_ivb_laptops/ tree, which already contains
#  BOARD_HP_4430S with MAINBOARD_HAS_LIBGFXINIT + all required selects), drops
#  in the EC blobs, registers nothing extra (src/mainboard/hp/Kconfig sources
#  the subdir via glob), then builds the cross-toolchain and the 4 MB ROM
#  (build/coreboot.rom).
#
#  Override the coreboot version with:  COREBOOT_REF=25.12 bash ci_build.sh
#
#  IMPORTANT (lessons learned the hard way):
#   * Do NOT append a partial "delta" Kconfig to the upstream generic
#     src/mainboard/hp/snb_ivb_laptops/Kconfig. The upstream file already
#     defines VARIANT_DIR / MAINBOARD_PART_NUMBER / KBC1126_FW* INSIDE its
#     `if BOARD_HP_SNB_IVB_LAPTOPS_COMMON` block. A delta that re-declares
#     those symbols creates DUPLICATE symbols -> Kconfig fails to parse the
#     whole file -> BOARD_HP_4430S is never registered -> `make` silently
#     falls back to the QEMU emulation board (black screen on real HW).
#     Fix: overwrite the upstream generic Kconfig/name with the port's
#     complete versions, which integrate 4430s cleanly.
#   * libgfxinit (native GFX, Ada) is what gives EDK2/UEFI a GOP framebuffer.
#     Without it the UEFI payload has no display. buildgcc's have_gnat()
#     needs gnat-14 wired to bare `gnat`/`gnatbind`/`gnatmake` (see below).
# =============================================================================
set -euo pipefail

PORTDIR="$(cd "$(dirname "$0")" && pwd)"
CBDIR="$PORTDIR/coreboot"
GENERIC="$PORTDIR/src/mainboard/hp/snb_ivb_laptops"
VARIANT="$GENERIC/variants/4430s"
COREBOOT_REF="${COREBOOT_REF:-26.06}"

echo "==> coreboot ref: $COREBOOT_REF"

echo "==> cloning coreboot ($COREBOOT_REF) + submodules"
if [ ! -d "$CBDIR/.git" ]; then
    git clone --depth 1 --branch "$COREBOOT_REF" https://github.com/coreboot/coreboot.git "$CBDIR"
fi
cd "$CBDIR"
# SeaBIOS is NOT a submodule at 26.06 -- the build clones it on its own
# (payloads/external/SeaBIOS/Makefile: `git clone review.coreboot.org/seabios.git`).
# Only init the submodules this SNB/IVB + libgfxinit + microcode build needs.
git submodule update --init --checkout --depth 1 \
    3rdparty/blobs \
    3rdparty/intel-microcode \
    3rdparty/libgfxinit

# Use the GitHub mirror of SeaBIOS for a faster/more reliable clone on CI.
sed -i 's#review.coreboot.org/seabios.git#github.com/coreboot/seabios.git#' \
    payloads/external/SeaBIOS/Makefile

# coreboot's util/crossgcc/buildgcc (have_gnat) checks for ALL THREE unversioned
# GNAT tools (see buildgcc lines ~232-260):
#   1. hostcc_has_gnat1    : `$CC -print-prog-name=gnat1` must resolve to an
#                            executable. `gnat-14` ships /usr/lib/gcc/.../14/gnat1,
#                            so CC=gcc-14 (set in build.yml) finds it.
#   2. hostcc_has_gnatbind : `gnatbind` must be on PATH (unversioned).
#   3. hostcc_has_gnatmake : `gnatmake` must be on PATH (unversioned).
# Ubuntu 24.04 noble only ships `gnat-14` (versioned binaries); we symlink them
# to bare names at /usr/local/bin/ which is earlier on PATH than /usr/bin.
echo "==> wiring host GNAT (gnat-14 -> gnat/gnatbind/gnatmake/...) for libgfxinit/Ada"
for t in gnat gnatbind gnatmake gnatlink gnatclean; do
    if [ -x "/usr/bin/$t-14" ]; then
        sudo ln -sf "/usr/bin/$t-14" "/usr/local/bin/$t"
    fi
done
command -v gnat     >/dev/null && gnat     --version | head -1 || echo "WARN: gnat not found"
command -v gnatbind >/dev/null && echo "  gnatbind OK: $(command -v gnatbind)"
command -v gnatmake >/dev/null && echo "  gnatmake OK: $(command -v gnatmake)"
# Sanity: does CC's gcc know where gnat1 lives?
"${CC:-gcc}" -print-prog-name=gnat1 || true

echo "==> deploying 4430s board (port's complete SNB/IVB HP Kconfig + variant)"
# The port's src/mainboard/hp/snb_ivb_laptops/Kconfig is the COMPLETE board
# definition: it already contains BOARD_HP_4430S with MAINBOARD_HAS_LIBGFXINIT
# and all selects, integrated cleanly INSIDE the SNB_IVB_LAPTOPS_COMMON block
# (no duplicate symbols). We overwrite the upstream generic Kconfig with it so
# 4430s is properly registered. src/mainboard/hp/Kconfig sources this dir via
# GLOB (`src/mainboard/hp/*/Kconfig`), so no extra parent wiring is needed.
mkdir -p src/mainboard/hp/snb_ivb_laptops/variants/4430s
cp -f "$GENERIC/Kconfig"      src/mainboard/hp/snb_ivb_laptops/Kconfig
cp -f "$GENERIC/Kconfig.name" src/mainboard/hp/snb_ivb_laptops/Kconfig.name
cp -rf "$VARIANT"/.            src/mainboard/hp/snb_ivb_laptops/variants/4430s/
# sanity: confirm 4430s is registered before we waste ~20 min building
grep -q "config BOARD_HP_4430S" src/mainboard/hp/snb_ivb_laptops/Kconfig \
  && echo "  OK: BOARD_HP_4430S registered" \
  || { echo "FATAL: BOARD_HP_4430S missing after deploy"; exit 1; }

echo "==> installing EC blobs (validated SYSV checksums)"
mkdir -p 3rdparty/blobs/mainboard/hp/4430s
cp "$PORTDIR/3rdparty/blobs/mainboard/hp/4430s/ec_fw1.bin" 3rdparty/blobs/mainboard/hp/4430s/
cp "$PORTDIR/3rdparty/blobs/mainboard/hp/4430s/ec_fw2.bin" 3rdparty/blobs/mainboard/hp/4430s/

echo "==> configuring (CONFIG_BOARD_HP_4430S=y)"
cp "$PORTDIR/4430s_defconfig" .config
make olddefconfig

# Self-heal: if the defconfig dropped BOARD_HP_4430S (e.g. VENDOR_HP missing
# so the board symbol was invisible inside `if VENDOR_HP`), force the HP vendor
# on and re-run olddefconfig once. This is the exact silent-QEMU trap that bit
# us before; rather than fail blind we give kconfig a second chance.
if ! grep -q "^CONFIG_BOARD_HP_4430S=y" .config; then
    echo "  WARN: BOARD_HP_4430S not selected after first olddefconfig."
    echo "        Injecting CONFIG_VENDOR_HP=y and re-running olddefconfig..."
    ( grep -v "^CONFIG_VENDOR_HP=" .config; echo "CONFIG_VENDOR_HP=y" ) > .config.tmp
    mv -f .config.tmp .config
    make olddefconfig
fi

echo "==> verifying the selected board is really the 4430s (NOT QEMU fallback)"
if ! grep -q "^CONFIG_BOARD_HP_4430S=y" .config; then
    echo "FATAL: BOARD_HP_4430S not selected -- board registration failed."
    echo "---- .config board-related lines ----"
    grep -iE "BOARD_|VENDOR_|EMULATION" .config | head -40 || true
    exit 1
fi
if grep -q "^CONFIG_VENDOR_EMULATION=y" .config; then
    echo "FATAL: build still selected the QEMU/emulation board. Aborting."
    exit 1
fi
# Also verify CONFIG_VARIANT_DIR is set and non-empty. If it is empty the
# build will fail ~15 min later with "variants//overridetree.cb: No rule to
# make target" -- that's the symptom of an unescaped $(CONFIG_VARIANT_DIR)
# inside OVERRIDE_DEVICETREE getting expanded by kconfig at parse time when
# VARIANT_DIR's default hasn't been computed yet. Catch it here instead.
if ! grep -q '^CONFIG_VARIANT_DIR=' .config; then
    echo "FATAL: CONFIG_VARIANT_DIR not set -- Kconfig default chain didn't apply."
    exit 1
fi
VARIANT_DIR_VAL=$(grep '^CONFIG_VARIANT_DIR=' .config | head -1 | sed -E 's/^CONFIG_VARIANT_DIR=//; s/^"//; s/"$//')
if [ -z "$VARIANT_DIR_VAL" ]; then
    echo "FATAL: CONFIG_VARIANT_DIR is empty -- variants//overridetree.cb will break the build."
    exit 1
fi
echo "  OK: BOARD_HP_4430S selected (variant=$VARIANT_DIR_VAL), no emulation fallback."

echo "==> building cross-toolchain i386 (one-time, ~10-20 min)"
# Pre-stage the crossgcc tarballs from the coreboot mirror so the build script
# finds them in util/crossgcc/tarballs/ and skips its own download entirely.
# (buildgcc's USE_COREBOOT_MIRROR env var is reset to 0 at the top of the
# script and the only way to enable it via make is the -m flag, which
# util/crossgcc/Makefile.mk doesn't pass. Pre-staging is the only reliable
# workaround; the buildgcc download() function checks the cache first.)
mkdir -p util/crossgcc/tarballs
COREBOOT_MIRROR="https://www.coreboot.org/releases/crossgcc-sources"
for tarball in \
    gmp-6.3.0.tar.xz \
    mpfr-4.2.2.tar.xz \
    mpc-1.3.1.tar.gz \
    gcc-15.2.0.tar.xz \
    binutils-2.45.1.tar.xz \
    acpica-unix-20251212.tar.gz \
    nasm-3.01.tar.bz2; do
    if [ ! -f "util/crossgcc/tarballs/$tarball" ]; then
        echo "    fetching $tarball"
        curl -fsSL --retry 3 -o "util/crossgcc/tarballs/$tarball" \
            "$COREBOOT_MIRROR/$tarball" \
            || echo "    WARN: failed to fetch $tarball (buildgcc will retry)"
    fi
done
make crossgcc-i386 CPUS="$(nproc)"

# ---------------------------------------------------------------------------
# H6 console fix: UefiPayloadPkg does NOT schedule ConSplitterDxe /
# GraphicsConsoleDxe (they are "schedule on request"), so on real hardware
# EDK2 has NO ConIn/ConOut -> black screen even though coreboot POSTs.
# Force-dispatch them with [Depex] TRUE. We pre-clone EDK2 into the exact
# path coreboot's edk2 Makefile expects (so it skips its own clone) and
# patch the .inf files. The patch is left UNCOMMITTED so the Makefile's
# "git status ... | grep clean" check treats the tree as dirty and SKIPS
# its `git checkout --detach <tag> -f` (which would otherwise revert us).
# ---------------------------------------------------------------------------
echo "==> H6 console fix: pre-cloning EDK2 and patching ConSplitter/GraphicsConsole"
EDK2_REPO="$(grep '^CONFIG_EDK2_REPOSITORY=' .config | tail -1 | cut -d= -f2 | tr -d '"')"
EDK2_TAG="$(grep '^CONFIG_EDK2_TAG_OR_REV=' .config | tail -1 | cut -d= -f2 | tr -d '"')"
# NOTE: must match coreboot's edk2 Makefile exactly:
#   EDK2_PATH_REPO_ROOT := $(word 3,$(subst /, ,$(EDK2_REPOSITORY)))
# `word` collapses the double-slash whitespace, so use awk (NOT `cut -f3`,
# which would treat the empty field from "//" as a real word and mismatch).
EDK2_PATH="payloads/external/edk2/workspace/$(echo "$EDK2_REPO" | tr '/' ' ' | awk '{print $3}')"
echo "    EDK2_REPO=$EDK2_REPO"
echo "    EDK2_TAG=$EDK2_TAG"
echo "    EDK2_PATH=$EDK2_PATH"
if [ ! -d "$EDK2_PATH/.git" ]; then
    git clone --recurse-submodules "$EDK2_REPO" "$EDK2_PATH"
    ( cd "$EDK2_PATH" && git checkout --detach "$EDK2_TAG" -f && git submodule update --init --checkout --recursive )
fi
python3 - "$EDK2_PATH" <<'PY'
import sys, pathlib
base = pathlib.Path(sys.argv[1])
files = [
    "MdeModulePkg/Universal/Console/ConSplitterDxe/ConSplitterDxe.inf",
    "MdeModulePkg/Universal/Console/GraphicsConsoleDxe/GraphicsConsoleDxe.inf",
]
for rel in files:
    p = base / rel
    t = p.read_text()
    marker = '[UserExtensions.TianoCore."ExtraFiles"]'
    ins = '\n# Force dispatch in UefiPayloadPkg (no platform a-priori scheduler)\n[Depex]\n  TRUE\n\n'
    if marker in t and '[Depex]' not in t.split(marker)[0]:
        t = t.replace(marker, ins + marker, 1)
        p.write_text(t)
        print("    patched", rel)
    else:
        print("    SKIP (already patched or marker missing):", rel)
PY

echo "==> building coreboot.rom (EDK2 payload now includes H6 console fix)"
make -j"$(nproc)"

# =============================================================================
# EC firmware handling.
#
# The 4430s KBC1126 EC will NOT power the board on unless its firmware blobs
# are present in the ROM. coreboot delivers them as CBFS files, and this
# requires BOTH of the following in 4430s_defconfig (the Makefile only adds
# ecfw1.bin/ecfw2.bin to CBFS when KBC1126_FIRMWARE=y, even though
# EC_HP_KBC1126_ECFW_IN_CBFS defaults to y):
#   1. CONFIG_EC_HP_KBC1126_ECFW_IN_CBFS=y -> bootblock gets ecfw_ptr.c, a
#      pointer the EC reads at 0xffffff00 locating its firmware in flash.
#   2. CONFIG_KBC1126_FIRMWARE=y            -> ecfw1.bin / ecfw2.bin are added
#      to CBFS as raw files at CONFIG_KBC1126_FW*_OFFSET.
# The blobs themselves are copied into 3rdparty/blobs/mainboard/hp/4430s/
# further up in this script, so the paths above resolve at build time.
#
# Offset trap (do NOT change casually): coreboot 26.06's 4430s variant
# defaults KBC1126_FW*_OFFSET to 0xFFF700/0xF80000, which in our FLAT 4 MB
# image land at physical 0x3FF700/0x380000 -- i.e. inside/adjacent to the
# bootblock, so cbfstool would corrupt it. 4430s_defconfig overrides them to
# H7's proven values 0xfffe8000/0xfffd0000 (~96 KB/192 KB from ROM top,
# physical 0x3e8000/0x3d0000) which sit in free space above the EDK2 payload.
# The ecfw_ptr and the blob placement share that offset, so the EC finds its
# firmware consistently and the board powers on.
# =============================================================================
# =============================================================================
# Payload swap: take the freshly built STANDARD EDK2 payload and place it into
# H7's correct-board + Flash-Descriptor/Intel-ME base image.
#
# Why: coreboot's own BOARD_HP_4430S (derived from 2560p) fails early init on
# the real 4430s (1-second power cutoff) and its flat layout has no Intel ME.
# H7's base (h7-recovery-base.bin = WORKING_COREBOOT_v1_POSTS_IVYBRIDGE) has
# the correct probook_4430s board init + FD/ME + a small SeaBIOS payload. We
# keep H7's board/ME and replace ONLY its SeaBIOS payload with OUR standard
# EDK2 (H6 console Depex fix applied above, NO Rufus-NTFS BdsDxe hack) so the
# machine does a normal UEFI boot and can start the Windows installer.
#
# This is exactly the cbfstool recipe H7 used (BUILD-COMMAND.txt), just with a
# clean payload and a clean base.
# =============================================================================
echo
echo "==> Swapping standard EDK2 payload into H7 base (probook_4430s + FD/ME)"
H7BASE="$PORTDIR/h7-recovery-base.bin"
FINAL="$PORTDIR/HP4430S_STD_EDK2_4MB.bin"
# cbfstool is a host tool. coreboot 26.06 may leave the binary in-tree at
# util/cbfstool/cbfstool OR under build/util/cbfstool, and the main `make`
# does not always leave the in-tree copy. Build it explicitly if missing and
# locate it robustly before the swap.
CBFSTOOL=""
for d in "$CBDIR/util/cbfstool" "$CBDIR/build/util/cbfstool"; do
    f=$(find "$d" -name cbfstool -type f 2>/dev/null | head -1)
    [ -n "$f" ] && { CBFSTOOL="$f"; break; }
done
if [ -z "$CBFSTOOL" ]; then
    echo "==> building cbfstool (host tool)"
    ( cd "$CBDIR" && make -C util/cbfstool ) 2>&1 | tail -5
    CBFSTOOL=$(find "$CBDIR/util/cbfstool" -name cbfstool -type f 2>/dev/null | head -1)
fi
[ -n "$CBFSTOOL" ] || { echo "FATAL: cbfstool not found after build"; exit 1; }
echo "    cbfstool: $CBFSTOOL"
[ -f "$H7BASE" ] || { echo "FATAL: h7-recovery-base.bin not found in port dir"; exit 1; }
# sanity: base must be a full 4 MB SPI image
BASE_SZ=$(stat -c%s "$H7BASE" 2>/dev/null || wc -c < "$H7BASE")
if [ "$BASE_SZ" -ne 4194304 ]; then
    echo "FATAL: h7-recovery-base.bin is $BASE_SZ bytes, expected 4194304"; exit 1
fi
# Use the RAW EDK2 FV that coreboot 26.06's edk2 Makefile emits. The
# `UefiPayloadPkg` target `mv`s UEFIPAYLOAD.fd -> ../../../build/UEFIPAYLOAD.fd
# (i.e. $CBDIR/build/UEFIPAYLOAD.fd). This is the un-wrapped UEFI FV -- exactly
# the file H7's cbfstool recipe adds via `add-payload -f UEFIPAYLOAD.fd -c lzma`.
# Feeding it directly (instead of extracting the already-wrapped payload from
# coreboot.rom and re-adding it) avoids any double-wrapping and reproduces H7's
# known-good swap. coreboot 26.06's cbfstool requires -m ARCH on add-payload.
EDK2_FD=""
for cand in "$CBDIR/build/UEFIPAYLOAD.fd" \
            "$(find "$CBDIR/build" -name UEFIPAYLOAD.fd -type f 2>/dev/null | head -1)" \
            "$(find "$CBDIR/payloads/external/edk2" -name UEFIPAYLOAD.fd -type f 2>/dev/null | head -1)"; do
    [ -n "$cand" ] && [ -f "$cand" ] && { EDK2_FD="$cand"; break; }
done
if [ -z "$EDK2_FD" ]; then
    echo "FATAL: UEFIPAYLOAD.fd not found under $CBDIR (edk2 build output missing)"
    exit 1
fi
PAY_SZ=$(stat -c%s "$EDK2_FD" 2>/dev/null || wc -c < "$EDK2_FD")
echo "    EDK2 FV: $EDK2_FD ($PAY_SZ bytes, raw UEFI FV)"
# Copy base -> final, then swap the payload (remove SeaBIOS, add standard EDK2).
cp -f "$H7BASE" "$FINAL"
"$CBFSTOOL" "$FINAL" remove -n fallback/payload \
    || { echo "FATAL: cbfstool remove fallback/payload failed"; exit 1; }
"$CBFSTOOL" "$FINAL" add-payload -n fallback/payload -f "$EDK2_FD" -c lzma -m x86 \
    || { echo "FATAL: cbfstool add-payload failed (payload may exceed the 1 MB CBFS)"; exit 1; }
echo "==> verifying final ROM"
"$CBFSTOOL" "$FINAL" print | sed -n '1,80p'
# Confirm the payload is present and the ROM is still exactly 4 MB.
FINAL_SZ=$(stat -c%s "$FINAL" 2>/dev/null || wc -c < "$FINAL")
if [ "$FINAL_SZ" -ne 4194304 ]; then
    echo "FATAL: final ROM is $FINAL_SZ bytes, expected 4194304"; exit 1
fi
"$CBFSTOOL" "$FINAL" print | grep -q "fallback/payload" \
    || { echo "FATAL: fallback/payload missing from final ROM"; exit 1; }
echo "    OK: fallback/payload present in $FINAL ($FINAL_SZ bytes)"

echo
echo "==> DONE: $FINAL (4 MB, H7 probook_4430s board + FD/ME, standard EDK2 UEFI payload)"
echo "    (flat build kept at: $CBDIR/build/coreboot.rom -- board init discarded)"
ls -l "$FINAL" "$CBDIR/build/coreboot.rom"
