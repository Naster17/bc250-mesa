#!/usr/bin/env bash
# bc250-mesa: fetch upstream Mesa (GitLab), apply BC-250 patches, build RADV.
#
# Upstream: https://gitlab.freedesktop.org/mesa/mesa
# This repo is NOT a Mesa fork; it is a patch + build overlay for the AMD BC-250
# (gfx1013 / PS5 Oberon APU). See README.md.
#
# Usage:
#   ./build.sh                 # clone upstream main, apply patches, build
#   MESA_REF=mesa-25.0.0 ./build.sh   # pin a tag/branch
#   PREFIX=/opt/bc250-mesa ./build.sh
#
# Result: $MESA_DIR/build/src/amd/vulkan/libvulkan_radeon.so
# Use it:  VK_ICD_FILENAMES=$MESA_DIR/build/src/amd/vulkan/radeon_devenv_icd.x86_64.json <app>
set -euo pipefail

UPSTREAM="${UPSTREAM:-https://gitlab.freedesktop.org/mesa/mesa.git}"
MESA_REF="${MESA_REF:-main}"
MESA_DIR="${MESA_DIR:-$PWD/mesa}"
PREFIX="${PREFIX:-$HOME/.local}"
JOBS="${JOBS:-$(nproc)}"
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "== bc250-mesa build =="
echo "upstream: $UPSTREAM @ $MESA_REF"
echo "src dir : $MESA_DIR"
echo "prefix  : $PREFIX"

# 1. Fetch upstream Mesa. Shallow clone of the requested ref; fall back to a
#    tarball if git transport is unavailable.
if [ ! -d "$MESA_DIR/.git" ] && [ ! -f "$MESA_DIR/meson.build" ]; then
    echo "== fetching upstream Mesa =="
    if git clone --depth 1 --branch "$MESA_REF" "$UPSTREAM" "$MESA_DIR" 2>/dev/null; then
        :
    else
        echo "git clone failed; trying tarball"
        curl -L -o /tmp/mesa-src.tar.gz \
            "https://gitlab.freedesktop.org/mesa/mesa/-/archive/$MESA_REF/mesa-$MESA_REF.tar.gz"
        mkdir -p "$MESA_DIR"
        tar xzf /tmp/mesa-src.tar.gz -C "$MESA_DIR" --strip-components=1
    fi
fi

# 2. Apply patches if any (idempotent). NOTE: there are currently NO patches --
#    stock Mesa is correct for gfx1013 (the int-dot enablement was harmful and
#    removed; see docs/GFX1013-DOT-HAZARD.md). This builds a stock RADV driver.
cd "$MESA_DIR"
for p in "$HERE"/patches/*.patch; do
    [ -e "$p" ] || continue
    if git apply --check --reverse "$p" 2>/dev/null; then
        echo "== already applied: $(basename "$p")"
    elif git apply --check "$p" 2>/dev/null; then
        echo "== applying: $(basename "$p")"
        git apply "$p"
    else
        echo "!! patch does not apply cleanly (upstream moved?): $(basename "$p")" >&2
        echo "   inspect manually: git apply --3way $p" >&2
        exit 1
    fi
done

# 3. Python packaging module (Mesa meson needs it; Python 3.12+ dropped distutils).
python3 -c "import packaging" 2>/dev/null || \
    python3 -m pip install --user --break-system-packages packaging

# 4. Configure: RADV only (no OpenGL/gallium), LLVM enabled, release.
if [ ! -f build/build.ninja ]; then
    echo "== meson setup =="
    meson setup build \
        -Dvulkan-drivers=amd \
        -Dgallium-drivers= \
        -Dopengl=false -Dgles1=false -Dgles2=false \
        -Dglx=disabled -Degl=disabled -Dgbm=disabled \
        -Dllvm=enabled \
        -Dbuildtype=release \
        -Dprefix="$PREFIX"
fi

# 5. Build.
echo "== ninja build (-j$JOBS) =="
ninja -C build

echo
echo "== done =="
echo "driver: $MESA_DIR/build/src/amd/vulkan/libvulkan_radeon.so"
echo "ICD   : $MESA_DIR/build/src/amd/vulkan/radeon_devenv_icd.x86_64.json"
echo "test  : VK_ICD_FILENAMES=$MESA_DIR/build/src/amd/vulkan/radeon_devenv_icd.x86_64.json vulkaninfo --summary"