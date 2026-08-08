#!/usr/bin/env bash
# =============================================================================
#  ci_build.sh -- build coreboot for HP ProBook 4430s.
#
#  Runs on GitHub Actions (ubuntu-latest) and also locally on any Linux box.
#  It clones coreboot, drops in the 4430s variant + EC blobs, REGISTERS the
#  board by appending a small delta to the upstream generic SNB/IVB HP Kconfig
#  (so it stays compatible with whatever coreboot version is pinned), then
#  builds the cross-toolchain and the 4 MB ROM (build/coreboot.rom).
#
#  Override the coreboot version with:  COREBOOT_REF=25.12 bash ci_build.sh
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
# (the default review.coreboot.org also works; this is just insurance)
sed -i 's#review.coreboot.org/seabios.git#github.com/coreboot/seabios.git#' \
    payloads/external/SeaBIOS/Makefile

echo "==> installing 4430s variant files"
mkdir -p src/mainboard/hp/snb_ivb_laptops/variants/4430s
cp -r "$VARIANT"/. src/mainboard/hp/snb_ivb_laptops/variants/4430s/

echo "==> registering 4430s in the generic SNB/IVB HP board Kconfig (append delta)"
KG="src/mainboard/hp/snb_ivb_laptops/Kconfig"
KN="src/mainboard/hp/snb_ivb_laptops/Kconfig.name"

# Idempotent: only append if not already registered.
if ! grep -q "BOARD_HP_4430S" "$KG"; then
cat >> "$KG" <<'EOF'

# --- HP ProBook 4430s (added by 4430s port) ---
config BOARD_HP_4430S
	select BOARD_HP_SNB_IVB_LAPTOPS_COMMON
	select BOARD_ROMSIZE_KB_4096
	select GFX_GMA_PANEL_1_ON_LVDS
	select INTEL_GMA_HAVE_VBT
	select INTEL_INT15
	select MAINBOARD_HAS_LIBGFXINIT
	select SOUTHBRIDGE_INTEL_BD82X6X
	select KBC1126_FIRMWARE
	select EC_HP_KBC1126_ECFW_IN_CBFS

# defaults layered onto the already-defined symbols below
config VARIANT_DIR
	default "4430s" if BOARD_HP_4430S

config MAINBOARD_PART_NUMBER
	default "ProBook 4430s" if BOARD_HP_4430S

config USBDEBUG_HCD_INDEX
	default 1 if BOARD_HP_4430S # FIXME: verify against 4430s boardview

# KBC1126 EC firmware blob placement (4 MB ROM). Field values are the 24-bit
# top-of-ROM addresses from the backup's EC pointer table (ROM_end - 0x100);
# ecfw_ptr.c writes them back and the blobs land at the same file offsets the
# factory HP image used, so the EC finds them.
config KBC1126_FW1
	default "3rdparty/blobs/mainboard/hp/4430s/ec_fw1.bin" if BOARD_HP_4430S

config KBC1126_FW1_OFFSET
	default 0xFFF700 if BOARD_HP_4430S

config KBC1126_FW2
	default "3rdparty/blobs/mainboard/hp/4430s/ec_fw2.bin" if BOARD_HP_4430S

config KBC1126_FW2_OFFSET
	default 0xF80000 if BOARD_HP_4430S
EOF
fi

if ! grep -q "BOARD_HP_4430S" "$KN"; then
cat >> "$KN" <<'EOF'

config BOARD_HP_4430S
	bool "ProBook 4430s"
EOF
fi

echo "==> installing EC blobs (validated SYSV checksums)"
mkdir -p 3rdparty/blobs/mainboard/hp/4430s
cp "$PORTDIR/3rdparty/blobs/mainboard/hp/4430s/ec_fw1.bin" 3rdparty/blobs/mainboard/hp/4430s/
cp "$PORTDIR/3rdparty/blobs/mainboard/hp/4430s/ec_fw2.bin" 3rdparty/blobs/mainboard/hp/4430s/

echo "==> configuring (CONFIG_BOARD_HP_4430S=y)"
cp "$PORTDIR/4430s_defconfig" .config
make olddefconfig

echo "==> building cross-toolchain i386 (one-time, ~10-20 min)"
make crossgcc-i386 CPUS="$(nproc)"

echo "==> building coreboot.rom"
make -j"$(nproc)"

echo
echo "==> DONE: $CBDIR/build/coreboot.rom (4 MB)"
ls -l "$CBDIR/build/coreboot.rom"
