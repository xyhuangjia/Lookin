#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${LOOKINCTL_REPO_URL:-https://github.com/QMUI/Lookin.git}"
REF="${LOOKINCTL_REF:-master}"
RELEASE_URL="${LOOKINCTL_RELEASE_URL:-https://github.com/QMUI/Lookin/releases/latest/download/lookinctl-macos-universal.tar.gz}"
INSTALL_DIR="${LOOKINCTL_INSTALL_DIR:-}"
SCRIPT_PATH="${BASH_SOURCE[0]:-}"
LOCAL_ROOT=""

if [[ -n "${SCRIPT_PATH}" && -f "${SCRIPT_PATH}" ]]; then
  LOCAL_ROOT="$(cd "$(dirname "${SCRIPT_PATH}")/.." && pwd)"
fi

if [[ -z "${INSTALL_DIR}" ]]; then
  if [[ -w "/usr/local/bin" ]]; then
    INSTALL_DIR="/usr/local/bin"
  else
    INSTALL_DIR="${HOME}/.local/bin"
  fi
fi

mkdir -p "${INSTALL_DIR}"

tmpdir="$(mktemp -d)"
cleanup() {
  rm -rf "${tmpdir}"
}
trap cleanup EXIT

install_binary() {
  local binary="$1"
  install -m 0755 "${binary}" "${INSTALL_DIR}/lookinctl"
  echo "Installed lookinctl to ${INSTALL_DIR}/lookinctl"
  if ! command -v lookinctl >/dev/null 2>&1; then
    echo "Add ${INSTALL_DIR} to PATH if your shell cannot find lookinctl."
  fi
}

if [[ -n "${LOCAL_ROOT}" && -x "${LOCAL_ROOT}/Build/lookinctl/lookinctl" ]]; then
  install_binary "${LOCAL_ROOT}/Build/lookinctl/lookinctl"
  exit 0
fi

if curl -fsSL "${RELEASE_URL}" -o "${tmpdir}/lookinctl.tar.gz"; then
  mkdir -p "${tmpdir}/release"
  tar -xzf "${tmpdir}/lookinctl.tar.gz" -C "${tmpdir}/release"
  binary="$(find "${tmpdir}/release" -type f -name lookinctl | head -n 1 || true)"
  if [[ -z "${binary}" ]]; then
    echo "Release archive did not contain lookinctl." >&2
    exit 1
  fi
  install_binary "${binary}"
  exit 0
fi

if [[ -n "${LOCAL_ROOT}" && -x "${LOCAL_ROOT}/LookinCLI/build.sh" ]]; then
  echo "No release binary found at ${RELEASE_URL}; building local checkout."
  "${LOCAL_ROOT}/LookinCLI/build.sh" >/dev/null
  install_binary "${LOCAL_ROOT}/Build/lookinctl/lookinctl"
  exit 0
fi

echo "No release binary found at ${RELEASE_URL}; building from source."
echo "This fallback requires macOS Command Line Tools and git."

git clone --depth 1 --branch "${REF}" "${REPO_URL}" "${tmpdir}/Lookin"
"${tmpdir}/Lookin/LookinCLI/build.sh" >/dev/null
install_binary "${tmpdir}/Lookin/Build/lookinctl/lookinctl"
