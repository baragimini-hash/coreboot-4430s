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

echo "==> building coreboot.rom"
make -j"$(nproc)"

# =============================================================================
# Post-patch EC firmware blobs at their fixed ROM offsets.
#
# The 4430s has a 4 MB SPI mapped at physical 0xFFC00000..0xFFFFFFFF, but the
# backup ROM's EC firmware lives at physical 0xFFF700 (fw1) and 0xF80000 (fw2),
# which decode to file offsets 0x3FF700 and 0x380000 in the 4 MB image (the SPI
# decode window is bigger than the populated flash; the addresses are the
# 24-bit "top-of-ROM" values that the KBC1126 EC pointer table at
# ROM_end-0x100 stores). coreboot's cbfs-files mechanism can't place files at
# 0xFFF700 because that's outside the 4 MB image (it's a physical, not file,
# offset), so KBC1126_FIRMWARE is intentionally NOT selected. Instead we
# splice the blobs straight into the finished ROM image here. The bootblock's
# ecfw_ptr.c still writes the physical addresses into the pointer table.
# =============================================================================
echo "==> post-patching EC firmware into coreboot.rom at fixed file offsets"
ROM="$CBDIR/build/coreboot.rom"
FW1="$PORTDIR/3rdparty/blobs/mainboard/hp/4430s/ec_fw1.bin"
FW2="$PORTDIR/3rdparty/blobs/mainboard/hp/4430s/ec_fw2.bin"
FW1_OFF=0x3FF700   # physical 0xFFF700 (fw1, 2 KB, 2.25 KB from ROM end)
FW2_OFF=0x380000   # physical 0xF80000 (fw2, 63 KB)
[ -f "$ROM" ] || { echo "FATAL: $ROM not found"; exit 1; }
[ -f "$FW1" ] || { echo "FATAL: $FW1 not found"; exit 1; }
[ -f "$FW2" ] || { echo "FATAL: $FW2 not found"; exit 1; }
ROM_SIZE=$(stat -c%s "$ROM")
[ "$ROM_SIZE" -eq 4194304 ] || { echo "FATAL: $ROM is $ROM_SIZE bytes, expected 4194304 (4 MB)"; exit 1; }
# dd is the cleanest tool here: seek to the exact byte offset, write the blob,
# truncate the write to the blob size so nothing past it is touched.
dd if="$FW1" of="$ROM" bs=1 seek="$FW1_OFF" conv=notrunc status=none \
    || { echo "FATAL: dd fw1 -> $ROM @ $FW1_OFF failed"; exit 1; }
dd if="$FW2" of="$ROM" bs=1 seek="$FW2_OFF" conv=notrunc status=none \
    || { echo "FATAL: dd fw2 -> $ROM @ $FW2_OFF failed"; exit 1; }
echo "    OK: fw1 (2 KB)  -> offset 0x$(printf '%x' $FW1_OFF) (physical 0xFFF700)"
echo "    OK: fw2 (63 KB) -> offset 0x$(printf '%x' $FW2_OFF) (physical 0xF80000)"

echo
echo "==> DONE: $CBDIR/build/coreboot.rom (4 MB, EC fw patched in)"
ls -l "$CBDIR/build/coreboot.rom"
