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
# EC firmware handling (intentional NO-OP for the 4 MB 4430s flat layout).
#
# The 4430s KBC1126 EC firmware is delivered to the ROM two ways in coreboot:
#   1. As CBFS files via EC_HP_KBC1126_ECFW_IN_CBFS (default y), which the
#      bootblock loads at runtime. This is ALREADY done above (the blobs live
#      in 3rdparty/blobs/mainboard/hp/4430s/ and are pulled into CBFS). No
#      extra step needed.
#   2. As raw bytes spliced at physical 0xFFF700 / 0xF80000 (file 0x3FF700 /
#      0x380000). This is ONLY valid in an IFD layout where the top 512 KB is a
#      separate (EC) region below the BIOS region. In the FLAT layout we now
#      use for the 4 MB board, those offsets sit inside the bootblock /
#      reset-vector region at the very top of ROM, so a raw splice would
#      corrupt the bootblock and brick the image. We therefore DO NOT splice.
# The known-good TEST4 recovery ROM POSTs an Ivy Bridge CPU with NO EC blobs at
# those offsets, so the machine boots and runs on its stock EC firmware; the
# CBFS EC files above are a bonus if the bootblock chooses to load them.
# =============================================================================
echo
echo "==> DONE: $CBDIR/build/coreboot.rom (4 MB, flat layout, EC via CBFS)"
ls -l "$CBDIR/build/coreboot.rom"
