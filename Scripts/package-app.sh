#!/usr/bin/env bash
#
# 打包 Lookin.app 为可分发的 zip（兼容 Sparkle 1.x appcast），可选产出 dmg
#
# 用法:
#   Scripts/package-app.sh                          # App 缺失时先自动构建，然后打 zip
#   LOOKIN_PACKAGE_DMG=1 Scripts/package-app.sh     # 额外产出拖拽安装的 dmg
#   LOOKIN_PACKAGE_SUFFIX=beta Scripts/package-app.sh  # 文件名追加 -beta 后缀
#
# 环境变量:
#   LOOKIN_APP_PATH         指定待打包的 .app，默认 Build/LookinClient/Lookin.app
#   LOOKIN_PACKAGE_DMG      设为 1 同时产出 dmg
#   LOOKIN_PACKAGE_SUFFIX   产物文件名后缀（如 beta、rc1），默认为空

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/Build/LookinClient"
APP_PATH="${LOOKIN_APP_PATH:-${BUILD_DIR}/Lookin.app}"
PACKAGES_DIR="${BUILD_DIR}/packages"
LOOKIN_PACKAGE_DMG="${LOOKIN_PACKAGE_DMG:-0}"
LOOKIN_PACKAGE_SUFFIX="${LOOKIN_PACKAGE_SUFFIX:-}"

if [[ ! -d "${APP_PATH}" ]]; then
  echo "==> 未找到 ${APP_PATH}，先执行构建"
  "${ROOT_DIR}/Scripts/build-app.sh"
fi

# 兜底：待打包的 app 若为 ad-hoc 签名且未统一重签（如直接取 Xcode/xcodebuild 产物），
# 主程序与嵌入框架的 Team ID 不一致会导致安装后启动即崩，打包前先重签
if [[ "$(codesign -dv "${APP_PATH}" 2>&1)" == *"Signature=adhoc"* ]]; then
  echo "==> 检测到 ad-hoc 签名，统一重签内嵌代码: ${APP_PATH}"
  codesign --force --deep --sign - "${APP_PATH}"
fi

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP_PATH}/Contents/Info.plist")"
BASE_NAME="Lookin-${APP_VERSION}${LOOKIN_PACKAGE_SUFFIX:+-${LOOKIN_PACKAGE_SUFFIX}}"

mkdir -p "${PACKAGES_DIR}"
ARTIFACTS=()

# Sparkle 1.x 的 appcast 使用 zip；ditto 保留符号链接与可执行权限
ZIP_PATH="${PACKAGES_DIR}/${BASE_NAME}.zip"
echo "==> 打包 zip: ${BASE_NAME}.zip"
ditto -c -k --keepParent "${APP_PATH}" "${ZIP_PATH}"
echo "    $(du -h "${ZIP_PATH}" | cut -f1)  sha256: $(shasum -a 256 "${ZIP_PATH}" | cut -d' ' -f1)"
ARTIFACTS+=("${ZIP_PATH}")

if [[ "${LOOKIN_PACKAGE_DMG}" == "1" ]]; then
  DMG_PATH="${PACKAGES_DIR}/${BASE_NAME}.dmg"
  echo "==> 打包 dmg: ${BASE_NAME}.dmg"
  STAGING_DIR="$(mktemp -d)"
  trap 'rm -rf "${STAGING_DIR}"' EXIT
  ditto "${APP_PATH}" "${STAGING_DIR}/Lookin.app"
  ln -s /Applications "${STAGING_DIR}/Applications"
  hdiutil create -volname "Lookin" -srcfolder "${STAGING_DIR}" -format UDZO -ov -quiet "${DMG_PATH}"
  echo "    $(du -h "${DMG_PATH}" | cut -f1)  sha256: $(shasum -a 256 "${DMG_PATH}" | cut -d' ' -f1)"
  ARTIFACTS+=("${DMG_PATH}")
fi

echo "==> 完成，产物目录: ${PACKAGES_DIR}"
printf '%s\n' "${ARTIFACTS[@]}"
