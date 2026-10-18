# lookinctl npm package

Standalone npm distribution for `lookinctl`.

## Install

```sh
npm install -g lookinctl
lookinctl help
lookinctl devices
```

For a private npm registry:

```sh
npm install -g @your-scope/lookinctl --registry https://npm.example.com
```

This package ships a native macOS binary and a small Node.js wrapper. It does not depend on `Lookin.app`.

The bundled binary is ad-hoc signed by default, so it does not depend on an expiring certificate. During install and launch the wrapper removes `com.apple.quarantine` when present.

## Publish

From the Lookin repository:

```sh
LOOKINCTL_NPM_NAME=@your-scope/lookinctl \
LOOKINCTL_NPM_REGISTRY=https://npm.example.com \
LookinCLI/package-npm.sh --publish
```

To only create the tarball:

```sh
LookinCLI/package-npm.sh --name @your-scope/lookinctl --registry https://npm.example.com
```

The package artifacts use fixed paths:

```text
Build/lookinctl-npm/package/         generated package directory before packing
Build/lookinctl-npm/tarballs/        generated installable .tgz files
Build/lookinctl-npm/manifest.json    machine-readable artifact metadata
```

Use `Build/lookinctl-npm/tarballs/*.tgz` or the `tarball` field in `manifest.json` for upload and archive scripts.

For distribution signing:

```sh
LOOKINCTL_CODESIGN_IDENTITY="<codesign-identity>" \
LOOKINCTL_CODESIGN_OPTIONS="--timestamp --options runtime" \
LookinCLI/package-npm.sh --publish
```

## Notes

- The package is macOS-only.
- The generated package includes the native binary under `prebuilds/darwin-*/lookinctl`.
- Use `LOOKINCTL_BINARY=/absolute/path/to/lookinctl` to override the bundled binary.
