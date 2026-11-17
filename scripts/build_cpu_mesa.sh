#!/usr/bin/env bash
set -euo pipefail

# Rebuild the validated CPU-only stack; never install over an existing version.
# LLVM 15 development packages must be installed first (see the maintenance guide).
orbbec_prefix="${1:-/opt/orbbec-mesa-cpu/25.2.8}"
if [[ "$orbbec_prefix" != /* || -e "$orbbec_prefix/lib/libgallium-25.2.8.so" ]]; then
    echo "Choose an absolute, unused installation prefix: $orbbec_prefix" >&2
    exit 2
fi
if [[ $(id -u) != 0 ]]; then
    echo "Run as root in the Ubuntu 20.04 x86_64 build container." >&2
    exit 2
fi
source /etc/os-release
if [[ "$ID" != ubuntu || "$VERSION_ID" != 20.04 || $(uname -m) != x86_64 ]]; then
    echo "This recipe is validated only for Ubuntu 20.04 x86_64." >&2
    exit 2
fi
if ! command -v llvm-config-15 >/dev/null; then
    echo "Install llvm-15-dev from the official LLVM focal repository first." >&2
    exit 2
fi
orbbec_build=$(mktemp -d /tmp/orbbec-mesa-build.XXXXXX)
trap 'if [[ "${ORBBEC_KEEP_BUILD:-0}" != 1 ]]; then rm -rf -- "$orbbec_build"; else echo "Kept build tree: $orbbec_build"; fi' EXIT
export DEBIAN_FRONTEND=noninteractive
apt-get install -y --no-install-recommends \
    build-essential curl ca-certificates bison flex ninja-build python3-venv \
    python3-mako python3-packaging python3-yaml libpciaccess-dev libudev-dev \
    libglvnd-dev pkg-config
python3 -m venv --system-site-packages "$orbbec_build/tools"
"$orbbec_build/tools/bin/python" -m pip install --disable-pip-version-check 'meson==1.7.2'
export PATH="$orbbec_build/tools/bin:/usr/lib/llvm-15/bin:$PATH"
export PKG_CONFIG_PATH="$orbbec_prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export LD_LIBRARY_PATH="$orbbec_prefix/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

fetch_source() {
    local filename=$1 url=$2 checksum=$3
    if [[ -n "${ORBBEC_SOURCE_CACHE:-}" && -f "$ORBBEC_SOURCE_CACHE/$filename" ]]; then
        cp "$ORBBEC_SOURCE_CACHE/$filename" "$orbbec_build/$filename"
    else
        curl -fL --retry 3 --connect-timeout 20 -o "$orbbec_build/$filename" "$url"
    fi
    printf '%s  %s\n' "$checksum" "$orbbec_build/$filename" | sha256sum -c -
    tar -xf "$orbbec_build/$filename" -C "$orbbec_build"
}
fetch_source libdrm-2.4.125.tar.xz \
    https://dri.freedesktop.org/libdrm/libdrm-2.4.125.tar.xz \
    d4bae92797a50f81a93524762e0410a49cd84cfa0f997795bc0172ac8fb1d96a
fetch_source mesa-25.2.8.tar.xz \
    https://archive.mesa3d.org/mesa-25.2.8.tar.xz \
    097842f3e49d996868b38688db87b006f7d4541e93ce86d2f341d8b3e7be7c93

# Mesa's NIR generator uses str.removeprefix, absent in Ubuntu 20.04's Python 3.8.
# Apply the same equivalent build-time-only replacement as the successful build.
python3 - "$orbbec_build/mesa-25.2.8/src/compiler/nir/nir_algebraic.py" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
old = "m.group('swizzle').removeprefix('.')"
new = "(m.group('swizzle')[1:] if m.group('swizzle').startswith('.') else m.group('swizzle'))"
assert old in s, 'Source changed; review the Python 3.8 compatibility patch'
p.write_text(s.replace(old, new))
PY

meson setup "$orbbec_build/libdrm-build" "$orbbec_build/libdrm-2.4.125" \
    --prefix="$orbbec_prefix" --libdir=lib --buildtype=release --wrap-mode=nodownload \
    -Dauto_features=disabled -Dintel=enabled -Dtests=false
ninja -C "$orbbec_build/libdrm-build" -j"${ORBBEC_BUILD_JOBS:-8}"
ninja -C "$orbbec_build/libdrm-build" install
printf "[binaries]\nllvm-config = '/usr/bin/llvm-config-15'\n" > "$orbbec_build/llvm15-native.ini"
meson setup --native-file "$orbbec_build/llvm15-native.ini" \
    "$orbbec_build/mesa-build" "$orbbec_build/mesa-25.2.8" \
    --prefix="$orbbec_prefix" --libdir=lib --buildtype=release --wrap-mode=nodownload \
    -Dplatforms=[] -Degl-native-platform=surfaceless \
    -Dgallium-drivers=llvmpipe -Dvulkan-drivers=[] -Dllvm=enabled -Dshared-llvm=enabled \
    -Dllvm-orcjit=false -Dglx=disabled -Dglvnd=enabled -Dgbm=enabled -Degl=enabled \
    -Dgles1=disabled -Dgles2=enabled -Dgallium-va=disabled -Dgallium-vdpau=disabled \
    -Dvideo-codecs=[] -Dbuild-tests=false -Dvalgrind=disabled
ninja -C "$orbbec_build/mesa-build" -j"${ORBBEC_BUILD_JOBS:-8}"
ninja -C "$orbbec_build/mesa-build" install
echo "Installed CPU Mesa at $orbbec_prefix; temporary build files will be removed."
