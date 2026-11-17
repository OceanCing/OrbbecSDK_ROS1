#!/usr/bin/env bash
set -euo pipefail

# This prefix can be selected independently for each camera process.
orbbec_mesa_prefix="${ORBBEC_MESA_PREFIX:-/opt/orbbec-mesa-cpu/25.2.8}"
if [[ $# -eq 0 ]]; then
    echo "Usage: ORBBEC_MESA_PREFIX=/path/to/mesa $0 command [arguments...]" >&2
    exit 2
fi
if [[ ! -f "$orbbec_mesa_prefix/share/glvnd/egl_vendor.d/50_mesa.json" ]]; then
    echo "CPU Mesa is missing: $orbbec_mesa_prefix" >&2
    exit 1
fi
export LD_LIBRARY_PATH="$orbbec_mesa_prefix/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LIBGL_DRIVERS_PATH="$orbbec_mesa_prefix/lib/dri"
export __EGL_VENDOR_LIBRARY_FILENAMES="$orbbec_mesa_prefix/share/glvnd/egl_vendor.d/50_mesa.json"
export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=llvmpipe
export EGL_PLATFORM=surfaceless
export DISPLAY=
unset LD_PRELOAD MESA_LOADER_DRIVER_OVERRIDE

# The SDK enumerates EGL devices explicitly. Merely setting software-rendering
# environment variables does not prevent it from choosing the physical GPU.
# Hide that GPU only from this child process tree, without changing USB access.
echo "[cpu-mesa] prefix=$orbbec_mesa_prefix, driver=llvmpipe" >&2
exec unshare --mount --propagation private /bin/bash -c '
    if [[ -d /dev/dri ]]; then
        mount -t tmpfs -o mode=755,nosuid,nodev tmpfs /dev/dri
    fi
    exec "$@"
' bash "$@"
