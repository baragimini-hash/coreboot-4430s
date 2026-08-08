#!/usr/bin/env bash
# =============================================================================
#  build_4430s.sh -- build coreboot for the HP ProBook 4430s
#
#  What this does:
#   1. Clones coreboot (+ submodules: 3rdparty/blobs, payloads) into $CBDIR.
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
git submodule update --init --checkout --depth 1 3rdparty/blobs
# payload (SeaBIOS by default)
git submodule update --init --checkout --depth 1 payloads/seabios

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
make crossgcc-i386 CPUS=$(nproc)
echo "==> building coreboot.rom"
make -j$(nproc)

echo
echo "==> DONE. Flash: $CBDIR/build/coreboot.rom  (4 MB)"
echo "    Verify with:  ifdtool -n build/coreboot.rom"
