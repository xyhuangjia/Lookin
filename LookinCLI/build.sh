#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/Build/lookinctl"
LOOKIN_SHARED_DIR="${LOOKIN_SHARED_DIR:-${ROOT_DIR}/Pods/LookinShared}"

if [[ ! -d "${LOOKIN_SHARED_DIR}/Src/Main/Shared" ]]; then
  LOOKIN_SERVER_DIR="${BUILD_DIR}/LookinServer-1.2.7"
  if [[ ! -d "${LOOKIN_SERVER_DIR}/Src/Main/Shared" ]]; then
    rm -rf "${LOOKIN_SERVER_DIR}"
    mkdir -p "${BUILD_DIR}"
    git clone --depth 1 --branch 1.2.7 https://github.com/QMUI/LookinServer.git "${LOOKIN_SERVER_DIR}"
  fi
  LOOKIN_SHARED_DIR="${LOOKIN_SERVER_DIR}"
fi

mkdir -p "${BUILD_DIR}"

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
OUTPUT="${BUILD_DIR}/lookinctl"
LOOKINCTL_ARCHS="${LOOKINCTL_ARCHS:-$(uname -m)}"
LOOKINCTL_CODESIGN="${LOOKINCTL_CODESIGN:-1}"
LOOKINCTL_CODESIGN_IDENTITY="${LOOKINCTL_CODESIGN_IDENTITY:--}"
LOOKINCTL_CODESIGN_OPTIONS="${LOOKINCTL_CODESIGN_OPTIONS:-}"

ARCH_FLAGS=()
for arch in ${LOOKINCTL_ARCHS}; do
  ARCH_FLAGS+=("-arch" "${arch}")
done

SHARED_SOURCES=()
while IFS= read -r source_file; do
  SHARED_SOURCES+=("${source_file}")
done < <(find "${LOOKIN_SHARED_DIR}/Src/Main/Shared" "${LOOKIN_SHARED_DIR}/Src/Base" -name '*.m' | sort)

xcrun --sdk macosx clang \
  "${ARCH_FLAGS[@]}" \
  -fobjc-arc \
  -ObjC \
  -DSHOULD_COMPILE_LOOKIN_SERVER=1 \
  -include AppKit/AppKit.h \
  -mmacosx-version-min=11.0 \
  -isysroot "${SDK_PATH}" \
  -I"${LOOKIN_SHARED_DIR}/Src/Main/Shared" \
  -I"${LOOKIN_SHARED_DIR}/Src/Main/Shared/Category" \
  -I"${LOOKIN_SHARED_DIR}/Src/Main/Shared/Peertalk" \
  -I"${LOOKIN_SHARED_DIR}/Src/Base" \
  -framework Foundation \
  -framework AppKit \
  -framework QuartzCore \
  "${ROOT_DIR}/LookinCLI/main.m" \
  "${SHARED_SOURCES[@]}" \
  -o "${OUTPUT}"

if [[ "${LOOKINCTL_CODESIGN}" != "0" ]]; then
  # Default to ad-hoc signing. Set LOOKINCTL_CODESIGN_IDENTITY when a distribution
  # policy requires a specific signing identity.
  codesign --force --sign "${LOOKINCTL_CODESIGN_IDENTITY}" ${LOOKINCTL_CODESIGN_OPTIONS} "${OUTPUT}"
  codesign --verify --strict --verbose=2 "${OUTPUT}" >/dev/null
fi

echo "${OUTPUT}"
