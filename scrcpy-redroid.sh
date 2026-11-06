#!/usr/bin/env bash
# scrcpy-redroid.sh - scrcpy with VAAPI hardware decode for redroid.
# Usage: scrcpy-redroid.sh [scrcpy args...]
#   e.g. scrcpy-redroid -s 192.168.0.168:5555
# Auto-detects the local VAAPI driver so hardware decode "just works".
set -euo pipefail

# Respect an explicitly set, valid LIBVA_DRIVER_NAME; ignore empty/"drm".
cur="${LIBVA_DRIVER_NAME:-}"
if [ -z "$cur" ] || [ "$cur" = "drm" ]; then
  if command -v lspci >/dev/null 2>&1; then
    gpu=$(lspci 2>/dev/null | grep -iE "vga|3d|display" | head -1)
    case "$gpu" in
      *AMD*|*ATI*)    LIBVA_DRIVER_NAME=radeonsi ;;
      *Intel*)        LIBVA_DRIVER_NAME=iHD ;;
      *NVIDIA*)       LIBVA_DRIVER_NAME=nvidia ;;
      *)              LIBVA_DRIVER_NAME=radeonsi ;;
    esac
  else
    LIBVA_DRIVER_NAME=radeonsi
  fi
fi
export LIBVA_DRIVER_NAME

if [ -z "${LIBVA_DRIVERS_PATH:-}" ]; then
  for p in /usr/lib/dri /usr/lib/x86_64-linux-gnu/dri /usr/lib64/dri; do
    if [ -d "$p" ]; then export LIBVA_DRIVERS_PATH="$p"; break; fi
  done
fi

echo "scrcpy-redroid: LIBVA_DRIVER_NAME=$LIBVA_DRIVER_NAME  LIBVA_DRIVERS_PATH=${LIBVA_DRIVERS_PATH:-自动}"
exec scrcpy "$@"
