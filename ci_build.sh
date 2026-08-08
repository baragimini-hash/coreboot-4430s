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

# coreboot's buildgcc checks for a host `gnat` command to decide whether to
# build the cross gcc with the Ada front-end (required by libgfxinit). Ubuntu
# noble only ships `gnat-14`, so expose the bare names buildgcc expects.
echo "==> wiring host GNAT (gnat-14 -> gnat) for libgfxinit/Ada"
for t in gnat gnatmake gnatlink gnatclean; do
    if [ -x "/usr/bin/$t-14" ]; then
        sudo ln -sf "/usr/bin/$t-14" "/usr/local/bin/$t"
    fi
done
command -v gnat >/dev/null && gnat --version | head -1 || echo "WARN: gnat still not found"

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
	select INTEL_INT15
	# Native GFX (libgfxinit) IS enabled -- required so EDK2 (UEFI payload)
	# gets a GOP framebuffer. The variant's data.vbt was extracted from
	# the physically-working TEST4 v1 ROM (commit hash unknown; SHA-256
	# base 2b0902a7... is the recovery ROM). If the panel hangs training,
	# fall back to disabling MAINBOARD_HAS_LIBGFXINIT below.
	select MAINBOARD_HAS_LIBGFXINIT
	select GFX_GMA_PANEL_1_ON_LVDS
	select INTEL_GMA_HAVE_VBT
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

echo
echo "==> DONE: $CBDIR/build/coreboot.rom (4 MB)"
ls -l "$CBDIR/build/coreboot.rom"
