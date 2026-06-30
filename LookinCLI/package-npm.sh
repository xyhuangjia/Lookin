#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI_DIR="${ROOT_DIR}/LookinCLI"
NPM_TEMPLATE_DIR="${CLI_DIR}/npm"
BUILD_DIR="${ROOT_DIR}/Build/lookinctl-npm"
STAGE_DIR="${BUILD_DIR}/package"
TARBALL_DIR="${BUILD_DIR}/tarballs"
MANIFEST_PATH="${BUILD_DIR}/manifest.json"

PACKAGE_NAME="${LOOKINCTL_NPM_NAME:-lookinctl}"
PACKAGE_VERSION="${LOOKINCTL_NPM_VERSION:-}"
REGISTRY="${LOOKINCTL_NPM_REGISTRY:-}"
PUBLISH=0
NPM_CLIENT="${LOOKINCTL_NPM_CLIENT:-}"

usage() {
  cat <<'EOF'
Usage:
  LookinCLI/package-npm.sh [--name package-name] [--version version] [--registry url] [--publish]

Environment:
  LOOKINCTL_NPM_NAME      npm package name, e.g. @your-scope/lookinctl
  LOOKINCTL_NPM_VERSION   package version. Defaults to native lookinctl --version
  LOOKINCTL_NPM_REGISTRY  npm registry url
  LOOKINCTL_NPM_CLIENT    npm or pnpm executable path

Artifacts:
  Build/lookinctl-npm/package/       staged npm package directory
  Build/lookinctl-npm/tarballs/      generated .tgz package
  Build/lookinctl-npm/manifest.json  machine-readable artifact metadata
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      PACKAGE_NAME="$2"
      shift 2
      ;;
    --version)
      PACKAGE_VERSION="$2"
      shift 2
      ;;
    --registry)
      REGISTRY="$2"
      shift 2
      ;;
    --publish)
      PUBLISH=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "${NPM_CLIENT}" ]]; then
  if command -v npm >/dev/null 2>&1; then
    NPM_CLIENT="npm"
  elif command -v pnpm >/dev/null 2>&1; then
    NPM_CLIENT="pnpm"
  else
    echo "Neither npm nor pnpm was found in PATH. Install Node.js/npm or set LOOKINCTL_NPM_CLIENT=/path/to/npm." >&2
    exit 127
  fi
fi

"${CLI_DIR}/build.sh" >/dev/null
NATIVE_BINARY="${ROOT_DIR}/Build/lookinctl/lookinctl"
if [[ ! -x "${NATIVE_BINARY}" ]]; then
  echo "Native binary was not built: ${NATIVE_BINARY}" >&2
  exit 1
fi

if [[ -z "${PACKAGE_VERSION}" ]]; then
  PACKAGE_VERSION="$("${NATIVE_BINARY}" --version)"
fi

ARCHS="$(lipo -archs "${NATIVE_BINARY}" 2>/dev/null || true)"
if [[ "${ARCHS}" == *"arm64"* && "${ARCHS}" == *"x86_64"* ]]; then
  PREBUILD_DIR="darwin-universal"
  PACKAGE_CPUS='["arm64","x64"]'
elif [[ "${ARCHS}" == *"x86_64"* ]]; then
  PREBUILD_DIR="darwin-x64"
  PACKAGE_CPUS='["x64"]'
else
  PREBUILD_DIR="darwin-arm64"
  PACKAGE_CPUS='["arm64"]'
fi

rm -rf "${STAGE_DIR}" "${TARBALL_DIR}" "${MANIFEST_PATH}"
mkdir -p "${STAGE_DIR}" "${TARBALL_DIR}"
cp -R "${NPM_TEMPLATE_DIR}/." "${STAGE_DIR}/"
mkdir -p "${STAGE_DIR}/prebuilds/${PREBUILD_DIR}"
install -m 0755 "${NATIVE_BINARY}" "${STAGE_DIR}/prebuilds/${PREBUILD_DIR}/lookinctl"

node - "${STAGE_DIR}/package.json" "${PACKAGE_NAME}" "${PACKAGE_VERSION}" "${PACKAGE_CPUS}" <<'NODE'
const fs = require("fs");
const [packagePath, name, version, cpus] = process.argv.slice(2);
const pkg = JSON.parse(fs.readFileSync(packagePath, "utf8"));
pkg.name = name;
pkg.version = version;
pkg.cpu = JSON.parse(cpus);
fs.writeFileSync(packagePath, JSON.stringify(pkg, null, 2) + "\n");
NODE

chmod +x "${STAGE_DIR}/bin/lookinctl.js"

if [[ -n "${REGISTRY}" ]]; then
  (cd "${STAGE_DIR}" && "${NPM_CLIENT}" pack --registry "${REGISTRY}")
else
  (cd "${STAGE_DIR}" && "${NPM_CLIENT}" pack)
fi

TARBALL="$(find "${STAGE_DIR}" -maxdepth 1 -type f -name '*.tgz' | head -n 1)"
if [[ -z "${TARBALL}" ]]; then
  echo "npm pack did not produce a tarball." >&2
  exit 1
fi

FINAL_TARBALL="${TARBALL_DIR}/$(basename "${TARBALL}")"
mv "${TARBALL}" "${FINAL_TARBALL}"

node - "${MANIFEST_PATH}" "${PACKAGE_NAME}" "${PACKAGE_VERSION}" "${ARCHS}" "${PREBUILD_DIR}" "${STAGE_DIR}" "${FINAL_TARBALL}" "${NATIVE_BINARY}" "${REGISTRY}" <<'NODE'
const fs = require("fs");
const path = require("path");
const [
  manifestPath,
  packageName,
  packageVersion,
  archs,
  prebuildDir,
  stageDir,
  tarball,
  nativeBinary,
  registry,
] = process.argv.slice(2);
const manifest = {
  packageName,
  packageVersion,
  archs: archs.trim().split(/\s+/).filter(Boolean),
  prebuildDir,
  packageDir: path.resolve(stageDir),
  tarball: path.resolve(tarball),
  nativeBinary: path.resolve(nativeBinary),
  registry: registry || null,
};
fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + "\n");
NODE

echo "Staged package: ${STAGE_DIR}"
echo "Created tarball: ${FINAL_TARBALL}"
echo "Wrote manifest: ${MANIFEST_PATH}"

if [[ "${PUBLISH}" -eq 1 ]]; then
  if [[ -n "${REGISTRY}" ]]; then
    "${NPM_CLIENT}" publish "${FINAL_TARBALL}" --registry "${REGISTRY}"
  else
    "${NPM_CLIENT}" publish "${FINAL_TARBALL}"
  fi
fi
