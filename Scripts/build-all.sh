#!/usr/bin/env bash
#
# 一键构建打包整个项目：Lookin.app + lookinctl CLI + App zip 包
#
# 用法:
#   Scripts/build-all.sh                          # 构建 App 与 CLI，并打包 App
#   LOOKINCTL_ARCHS="arm64 x86_64" Scripts/build-all.sh  # CLI 产出 universal 二进制
#   LOOKIN_SKIP_PACKAGE=1 Scripts/build-all.sh    # 只构建，不打包
#   LOOKIN_CODESIGN_IDENTITY="-" Scripts/build-all.sh    # 无团队证书时 ad-hoc 签名 App
#
# 各环节的详细选项见 Scripts/build-app.sh、Scripts/package-app.sh、LookinCLI/build.sh。
# LookinServer 是 iOS 框架，无法在 mac 上直接构建验证，流程见 LookinServer/CLAUDE.md。

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOOKIN_SKIP_PACKAGE="${LOOKIN_SKIP_PACKAGE:-0}"

echo "==> [1/3] 构建 Lookin.app"
"${ROOT_DIR}/Scripts/build-app.sh"

echo "==> [2/3] 构建 lookinctl"
"${ROOT_DIR}/LookinCLI/build.sh"

if [[ "${LOOKIN_SKIP_PACKAGE}" != "1" ]]; then
  echo "==> [3/3] 打包 Lookin.app"
  "${ROOT_DIR}/Scripts/package-app.sh"
else
  echo "==> [3/3] 跳过打包（LOOKIN_SKIP_PACKAGE=1）"
fi

echo "==> 全部完成"
