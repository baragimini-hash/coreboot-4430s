#!/usr/bin/env bash
# =============================================================================
#  build_4430s.sh -- build coreboot for the HP ProBook 4430s
#
#  What this does:
#   1. Clones coreboot (+ submodules: 3rdparty/blobs, intel-microcode,
#      libgfxinit) into $CBDIR. SeaBIOS is cloned automatically by `make`.
#   2. Drops in the new `4430s` variant under src/mainboard/hp/snb_ivb_laptops.
#   3. Registers the variant in the generic board Kconfig / Kconfig.name.
#   4. Copies the extracted KBC1126 EC blobs (ec_fw1.bin / ec_fw2.bin).
#   5. Builds the cross-toolchain (once) and the ROM.
#
#  IMPORTANT:
#   * This MUST run on Linux (native or WSL2 with virtualization enabled).
#     The machine this port was prepared on had virtualization disabled, so it
#     could not be compiled here -- you must build it on a Linux host.
#   * The 4430s ships with HM65 (6-series PCH). To run an Ivy Bridge (Gen3) CPU
#     you ALSO need the 6-series PCH pin/tape mod; coreboot alone is not enough.
#     Flash only after the mod is done (or with a Sandy Bridge CPU for testing).
#   * Use an SPI programmer (CH341A + SOIC8 clip). Keep the original backup.
# =============================================================================
set -euo pipefail

CBDIR="${CBDIR:-$HOME/coreboot}"
COREBOOT_REF="${COREBOOT_REF:-26.06}"
PORTDIR="$(cd "$(dirname "$0")" && pwd)"      # this script's directory
GENERIC="$PORTDIR/src/mainboard/hp/snb_ivb_laptops"
VARIANT="$GENERIC/variants/4430s"

echo "==> coreboot ref        : $COREBOOT_REF"
echo "==> coreboot source dir : $CBDIR"
echo "==> port dir            : $PORTDIR"

# --- 1. clone (shallow) + submodules -----------------------------------------
if [ ! -d "$CBDIR/.git" ]; then
    git clone --depth 1 --branch "$COREBOOT_REF" https://github.com/coreboot/coreboot.git "$CBDIR"
fi
cd "$CBDIR"
# SeaBIOS is NOT a submodule at 26.06 -- `make` clones it automatically
# (payloads/external/SeaBIOS/Makefile: `git clone review.coreboot.org/seabios.git`).
# Only init the submodules this SNB/IVB + libgfxinit + microcode build needs.
git submodule update --init --checkout --depth 1 \
    3rdparty/blobs \
    3rdparty/intel-microcode \
    3rdparty/libgfxinit

# Use the GitHub mirror of SeaBIOS for a faster/more reliable clone.
sed -i 's#review.coreboot.org/seabios.git#github.com/coreboot/seabios.git#' \
    payloads/external/SeaBIOS/Makefile

# --- 2. install the 4430s variant --------------------------------------------
echo "==> installing variant files"
mkdir -p src/mainboard/hp/snb_ivb_laptops/variants/4430s
cp -r "$VARIANT"/. src/mainboard/hp/snb_ivb_laptops/variants/4430s/

# --- 3. register the variant in the generic board Kconfig --------------------
# (our copies already contain every other variant unchanged + 4430s added)
echo "==> patching generic board Kconfig / Kconfig.name"
cp "$GENERIC/Kconfig.name" src/mainboard/hp/snb_ivb_laptops/Kconfig.name
cp "$GENERIC/Kconfig"      src/mainboard/hp/snb_ivb_laptops/Kconfig

# --- 4. EC blobs -------------------------------------------------------------
echo "==> installing EC blobs"
mkdir -p 3rdparty/blobs/mainboard/hp/4430s
cp "$PORTDIR/3rdparty/blobs/mainboard/hp/4430s/ec_fw1.bin" 3rdparty/blobs/mainboard/hp/4430s/
cp "$PORTDIR/3rdparty/blobs/mainboard/hp/4430s/ec_fw2.bin" 3rdparty/blobs/mainboard/hp/4430s/

# --- 5. configure -----------------------------------------------------------
echo "==> configuring"
cp "$PORTDIR/4430s_defconfig" .config
make olddefconfig

# --- 6. toolchain + build ----------------------------------------------------
echo "==> building cross-toolchain (one-time, ~10-20 min)"
# Pre-stage the crossgcc tarballs from the coreboot mirror so the build script
# finds them in util/crossgcc/tarballs/ and skips its own download. This
# works around flaky upstream GNU mirrors and the fact that buildgcc's
# USE_COREBOOT_MIRROR env var is reset to 0 at the top of the script.
# (libgfxinit is Ada; if your GNAT doesn't match gcc, install gnat-N matching
# your gcc and re-add select MAINBOARD_HAS_LIBGFXINIT in the Kconfig.)
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
    [ -f "util/crossgcc/tarballs/$tarball" ] || \
        curl -fsSL --retry 3 -o "util/crossgcc/tarballs/$tarball" \
            "$COREBOOT_MIRROR/$tarball" \
            || echo "WARN: failed to fetch $tarball"
done
make crossgcc-i386 CPUS=$(nproc)
echo "==> building coreboot.rom"
make -j$(nproc)

echo
echo "==> DONE. Flash: $CBDIR/build/coreboot.rom  (4 MB)"
echo "    Verify with:  ifdtool -n build/coreboot.rom"
