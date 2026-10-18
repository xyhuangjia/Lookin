#!/usr/bin/env bash
#
# 构建 Lookin.app（macOS 客户端）
#
# 用法:
#   Scripts/build-app.sh                              # Release 构建
#   LOOKIN_CONFIGURATION=Debug Scripts/build-app.sh   # Debug 构建
#   LOOKIN_CODESIGN_IDENTITY="-" Scripts/build-app.sh # 无开发证书时使用 ad-hoc 签名
#
# 环境变量:
#   LOOKIN_SCHEME              默认 LookinClient；Testflight 渠道传 LookinTestflight
#   LOOKIN_CONFIGURATION       默认 Release
#   LOOKIN_CODESIGN_IDENTITY   默认留空，走工程配置（Automatic / Mac Developer）；
#                              设为 "-" 以 ad-hoc 签名，适合没有团队证书的机器
#   LOOKIN_SKIP_POD_INSTALL    设为 1 跳过 Pods 同步检查
#   LOOKIN_VERBOSE             设为 1 直接输出 xcodebuild 完整日志

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/Build/LookinClient"
DERIVED_DATA_DIR="${BUILD_DIR}/DerivedData"

LOOKIN_SCHEME="${LOOKIN_SCHEME:-LookinClient}"
LOOKIN_CONFIGURATION="${LOOKIN_CONFIGURATION:-Release}"
LOOKIN_CODESIGN_IDENTITY="${LOOKIN_CODESIGN_IDENTITY:-}"
LOOKIN_SKIP_POD_INSTALL="${LOOKIN_SKIP_POD_INSTALL:-0}"
LOOKIN_VERBOSE="${LOOKIN_VERBOSE:-0}"

# Podfile.lock 与 Pods/Manifest.lock 不一致时自动 pod install
if [[ "${LOOKIN_SKIP_POD_INSTALL}" != "1" ]]; then
  if [[ ! -f "${ROOT_DIR}/Pods/Manifest.lock" ]] \
    || ! diff -q "${ROOT_DIR}/Podfile.lock" "${ROOT_DIR}/Pods/Manifest.lock" >/dev/null 2>&1; then
    command -v pod >/dev/null 2>&1 || { echo "错误: Pods 不同步且未安装 CocoaPods" >&2; exit 1; }
    echo "==> Pods 与 Podfile.lock 不同步，执行 pod install"
    (cd "${ROOT_DIR}" && pod install)
  fi
fi

mkdir -p "${BUILD_DIR}"

XCODEBUILD_ARGS=(
  -workspace "${ROOT_DIR}/Lookin.xcworkspace"
  -scheme "${LOOKIN_SCHEME}"
  -configuration "${LOOKIN_CONFIGURATION}"
  -derivedDataPath "${DERIVED_DATA_DIR}"
)
if [[ -n "${LOOKIN_CODESIGN_IDENTITY}" ]]; then
  XCODEBUILD_ARGS+=(
    CODE_SIGN_STYLE=Manual
    CODE_SIGN_IDENTITY="${LOOKIN_CODESIGN_IDENTITY}"
    DEVELOPMENT_TEAM=""
    PROVISIONING_PROFILE_SPECIFIER=""
  )
fi
XCODEBUILD_ARGS+=(build)

# 默认将 xcodebuild 输出写入日志文件，失败时打印末尾片段，避免刷屏
LOG_FILE="${BUILD_DIR}/xcodebuild.log"
echo "==> xcodebuild ${LOOKIN_SCHEME} (${LOOKIN_CONFIGURATION})"
if [[ "${LOOKIN_VERBOSE}" == "1" ]]; then
  xcodebuild "${XCODEBUILD_ARGS[@]}"
else
  if ! xcodebuild "${XCODEBUILD_ARGS[@]}" >"${LOG_FILE}" 2>&1; then
    tail -n 100 "${LOG_FILE}" >&2
    echo "错误: 构建失败，完整日志见 ${LOG_FILE}" >&2
    exit 1
  fi
  echo "==> 构建日志: ${LOG_FILE}"
fi

APP_IN_DERIVED="${DERIVED_DATA_DIR}/Build/Products/${LOOKIN_CONFIGURATION}/Lookin.app"
if [[ ! -d "${APP_IN_DERIVED}" ]]; then
  echo "错误: 未找到构建产物 ${APP_IN_DERIVED}" >&2
  exit 1
fi

# ditto 拷贝以保留元数据与签名
OUTPUT_APP="${BUILD_DIR}/Lookin.app"
rm -rf "${OUTPUT_APP}"
ditto "${APP_IN_DERIVED}" "${OUTPUT_APP}"

if [[ "${LOOKIN_CODESIGN_IDENTITY}" == "-" ]]; then
  # ad-hoc 模式下 xcodebuild 给嵌入框架的签名与主程序的 ad-hoc 签名 Team ID 不一致，
  # dyld 会拒绝加载框架导致 App 启动失败，因此对整个 bundle 统一重签
  codesign --force --deep --sign - "${OUTPUT_APP}"
fi

codesign --verify --strict "${OUTPUT_APP}"

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${OUTPUT_APP}/Contents/Info.plist")"
echo "==> 完成: ${OUTPUT_APP} (v${APP_VERSION}, ${LOOKIN_CONFIGURATION})"
echo "${OUTPUT_APP}"
