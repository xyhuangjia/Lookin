#!/usr/bin/env bash
#
# 生成 Sparkle appcast 并发布到 gh-pages 分支（经 GitHub Pages 提供更新源）
#
# 前置条件:
#   1. 对应版本的 GitHub release 已发布（appcast 中 zip 的下载地址指向 release 资产）
#   2. zip 已由 Scripts/package-app.sh 产出，位于 Build/LookinClient/packages/
#   3. Sparkle EdDSA 私钥可用：默认读仓库外密钥文件（LookinApp 目录下的
#      sparkle-ed25519.key），或用 SPARKLE_ED_KEY_FILE 指定；都没有则回退本机钥匙串
#
# 用法:
#   Scripts/publish-appcast.sh                  # 扫描 packages/ 下所有符合条件的 zip
#   Scripts/publish-appcast.sh a.zip [b.zip …]  # 只发布指定 zip
#
# 环境变量:
#   GH_REPO             GitHub 仓库（owner/repo），默认 xyhuangjia/Lookin
#   PAGES_URL           appcast 的基准地址，默认 https://xyhuangjia.github.io/Lookin
#   SPARKLE_ED_KEY_FILE EdDSA 私钥文件路径，默认 <仓库>/../sparkle-ed25519.key
#
# 说明:
#   - 只有 Info.plist 的 SUFeedURL 已指向 PAGES_URL 的 zip 才会进入 appcast，
#     旧更新源（lookin.work）的历史包会被自动跳过，不会混入
#   - release notes 取自 GitHub release 的 body，渲染成 HTML 放在 notes/<版本>.html
#   - 私钥文件只允许放在仓库外；本脚本与仓库均不包含私钥

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGES_DIR="${ROOT_DIR}/Build/LookinClient/packages"
SIGN_UPDATE="${ROOT_DIR}/Pods/Sparkle/bin/sign_update"
WORKTREE_DIR="${ROOT_DIR}/Build/gh-pages"

GH_REPO="${GH_REPO:-xyhuangjia/Lookin}"
PAGES_URL="${PAGES_URL:-https://xyhuangjia.github.io/Lookin}"
FEED_URL="${PAGES_URL}/release/appcast.xml"

# EdDSA 私钥：优先用仓库外的密钥文件（避免依赖某台机器的钥匙串），找不到则回退钥匙串
KEY_FILE="${SPARKLE_ED_KEY_FILE:-${ROOT_DIR}/../sparkle-ed25519.key}"
[[ -f "${KEY_FILE}" ]] || KEY_FILE=""

if [[ $# -gt 0 ]]; then
  ZIPS=("$@")
else
  ZIPS=("${PACKAGES_DIR}"/Lookin-*.zip)
  # 剔除带后缀的产物（如 -beta），它们不该进稳定通道
  ELIGIBLE=()
  for z in "${ZIPS[@]}"; do
    [[ "${z}" =~ Lookin-[0-9.]+\.zip$ ]] && ELIGIBLE+=("${z}")
  done
  ZIPS=("${ELIGIBLE[@]:-}")
fi
[[ ${#ZIPS[@]} -gt 0 ]] || { echo "错误: 没有找到待发布的 zip" >&2; exit 1; }

TMP_DIR="$(mktemp -d /tmp/appcast-build.XXXX)"
ITEMS_DIR="${TMP_DIR}/items"
NOTES_DIR="${TMP_DIR}/notes"
mkdir -p "${ITEMS_DIR}" "${NOTES_DIR}"
trap 'rm -rf "${TMP_DIR}"' EXIT

# 逐个 zip 校验、签名，每个版本一个片段文件（文件名 = CFBundleVersion，纯数字）
for ZIP_PATH in "${ZIPS[@]}"; do
  PLIST_TMP="$(mktemp)"
  unzip -q -p "${ZIP_PATH}" 'Lookin.app/Contents/Info.plist' > "${PLIST_TMP}"

  APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${PLIST_TMP}")"
  BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${PLIST_TMP}")"
  ZIP_FEED_URL="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "${PLIST_TMP}" 2>/dev/null || true)"
  rm -f "${PLIST_TMP}"

  if [[ "${ZIP_FEED_URL}" != "${FEED_URL}" ]]; then
    echo "==> 跳过 ${ZIP_PATH##*/}: SUFeedURL 尚未指向 ${FEED_URL}"
    continue
  fi

  ENCLOSURE_URL="https://github.com/${GH_REPO}/releases/download/${APP_VERSION}/$(basename "${ZIP_PATH}")"
  if ! gh release view "${APP_VERSION}" --repo "${GH_REPO}" >/dev/null 2>&1; then
    echo "错误: ${APP_VERSION} 的 GitHub release 尚未发布，先发 release 再跑本脚本" >&2
    exit 1
  fi

  echo "==> 签名 ${ZIP_PATH##*/} (${APP_VERSION}, build ${BUILD_VERSION})"
  if [[ -n "${KEY_FILE}" ]]; then
    SIGN_OUT="$("${SIGN_UPDATE}" "${ZIP_PATH}" "${KEY_FILE}")"
  else
    SIGN_OUT="$("${SIGN_UPDATE}" "${ZIP_PATH}")"
  fi
  ED_SIG="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<<"${SIGN_OUT}")"
  LENGTH="$(sed -n 's/.*length="\([^"]*\)".*/\1/p' <<<"${SIGN_OUT}")"
  [[ -n "${ED_SIG}" && -n "${LENGTH}" ]] || { echo "错误: 解析 sign_update 输出失败: ${SIGN_OUT}" >&2; exit 1; }
  [[ "${BUILD_VERSION}" =~ ^[0-9]+$ ]] || { echo "错误: ${ZIP_PATH##*/} 的 CFBundleVersion 非纯数字，无法排序" >&2; exit 1; }

  PUB_DATE="$(stat -f '%Sm' -t '%a, %d %b %Y %H:%M:%S %z' "${ZIP_PATH}")"
  NOTES_LINK=""
  if RELEASE_BODY="$(gh release view "${APP_VERSION}" --repo "${GH_REPO}" --json body -q '.body' 2>/dev/null)" && [[ -n "${RELEASE_BODY}" ]]; then
    if gh api markdown -f text="${RELEASE_BODY}" -f mode=gfm \
        --repo "${GH_REPO}" > "${NOTES_DIR}/${APP_VERSION}.html" 2>/dev/null; then
      NOTES_LINK="<sparkle:releaseNotesLink>${PAGES_URL}/release/notes/${APP_VERSION}.html</sparkle:releaseNotesLink>"
    fi
  fi

  cat > "${ITEMS_DIR}/${BUILD_VERSION}.item" <<ITEM
      <item>
        <title>Lookin ${APP_VERSION}</title>
        ${NOTES_LINK}
        <pubDate>${PUB_DATE}</pubDate>
        <enclosure url="${ENCLOSURE_URL}"
                   sparkle:version="${BUILD_VERSION}"
                   sparkle:shortVersionString="${APP_VERSION}"
                   length="${LENGTH}"
                   type="application/octet-stream"
                   sparkle:edSignature="${ED_SIG}" />
      </item>
ITEM
done

shopt -s nullglob
ITEM_FILES=("${ITEMS_DIR}"/*.item)
shopt -u nullglob
[[ ${#ITEM_FILES[@]} -gt 0 ]] || { echo "错误: 没有可用的 appcast 条目" >&2; exit 1; }

# 组装 appcast.xml，条目按 build 号倒序（最新在前）
APPCAST='<?xml version="1.0" encoding="utf-8" standalone="yes"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Lookin 更新</title>
    <link>'"${PAGES_URL}"'</link>
    <description>Lookin macOS 客户端更新</description>
    <language>zh-cn</language>
'
for BUILD_NUM in $(ls "${ITEMS_DIR}" | sort -rn); do
  APPCAST+="$(cat "${ITEMS_DIR}/${BUILD_NUM}")"$'\n'
done
APPCAST+='  </channel>
</rss>
'

# 准备 gh-pages 工作区（首次以孤儿分支创建，只保留 release/ 目录；
# 注意孤儿分支在首次提交前没有 ref，需按工作区 HEAD 判断，不能用 show-ref）
if [[ ! -e "${WORKTREE_DIR}/.git" ]]; then
  git -C "${ROOT_DIR}" worktree add --detach "${WORKTREE_DIR}" >/dev/null
  (
    cd "${WORKTREE_DIR}"
    git checkout --orphan gh-pages
    git rm -rf --quiet . 2>/dev/null || true
  )
else
  BRANCH_NAME="$(git -C "${WORKTREE_DIR}" symbolic-ref --short -q HEAD || true)"
  [[ "${BRANCH_NAME}" == "gh-pages" ]] || { echo "错误: ${WORKTREE_DIR} 不在 gh-pages 分支上（当前: ${BRANCH_NAME:-detached}）" >&2; exit 1; }
fi

mkdir -p "${WORKTREE_DIR}/release/notes"
printf '%s\n' "${APPCAST}" > "${WORKTREE_DIR}/release/appcast.xml"
xmllint --noout "${WORKTREE_DIR}/release/appcast.xml"
cp -R "${NOTES_DIR}/." "${WORKTREE_DIR}/release/notes/"

cd "${WORKTREE_DIR}"
git add release
if git diff --cached --quiet; then
  echo "==> appcast 无变化，无需发布"
else
  LATEST="$(grep -o 'shortVersionString="[^"]*"' release/appcast.xml | head -1 | cut -d'"' -f2)"
  git commit -q -m "发布 appcast：${LATEST}"
  git push -q -u origin gh-pages
  echo "==> 已推送 gh-pages: $(git log -1 --oneline)"
fi

# 开启 GitHub Pages（已开启时报错忽略）
gh api "repos/${GH_REPO}/pages" -X POST -f 'source[branch]'=gh-pages -f 'source[path]'=/ >/dev/null 2>&1 || true
echo "==> 完成，feed 地址: ${FEED_URL}"
