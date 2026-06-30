# lookinctl

`lookinctl` is a standalone CLI for apps that integrate LookinServer. It talks to LookinServer directly and does not depend on `Lookin.app`.

## Quick Start

```sh
lookinctl help
lookinctl devices
lookinctl -s com.example.app shell screencap -p -o screen.png
lookinctl -s com.example.app shell lookin current-vc
lookinctl -s com.example.app shell uiautomator dump -o hierarchy.json
```

Targets can be selected by adb-like serial, bundle id, app index, or app name. Real-device serials look like `usb:<deviceID>:<port>`; simulator serials look like `simulator:<port>`.

The command shape intentionally follows adb where it helps:

```sh
lookinctl devices
lookinctl -s <target> shell uiautomator dump
lookinctl -s <target> shell screencap -p
lookinctl -s <target> shell input hit-test <x> <y>
lookinctl -s <target> shell input tap <x> <y>
```

Command help is available without connecting to an app:

```sh
lookinctl help
lookinctl help devices
lookinctl help shell
lookinctl help shell input
lookinctl help shell lookin
lookinctl help screencap
lookinctl help dump
```

## Install

Published binary:

```sh
curl -fsSL https://raw.githubusercontent.com/QMUI/Lookin/master/LookinCLI/install.sh | bash
```

Local source checkout:

```sh
LookinCLI/build.sh
LOOKINCTL_INSTALL_DIR=/usr/local/bin LookinCLI/install.sh
```

npm package from a private registry:

```sh
npm install -g @your-scope/lookinctl --registry https://npm.example.com
lookinctl devices
```

## Common Use Cases

### Capture a UI Incident Without Opening Lookin.app

Problem: a developer, QA engineer, CI job, or agent needs the current app state, but launching the macOS Lookin UI is too heavy or unavailable.

Use:

```sh
lookinctl -s com.example.app shell screencap -p -o screen.png
lookinctl -s com.example.app shell uiautomator dump -o hierarchy.json
lookinctl -s com.example.app shell lookin current-vc -o current-vc.json
```

This produces a screenshot, hierarchy JSON, and current view-controller attribution that can be attached to bug reports or automation logs.

### Debug Automation Failures

Problem: an automation step says "button not found" or "tap did nothing", but the failure log does not explain the UI state.

Use:

```sh
lookinctl -s com.example.app shell input hit-test 585 933 -o hit.json
lookinctl -s com.example.app shell lookin hierarchy --max-depth 6 -o hierarchy.json
```

This answers whether the coordinate hits the expected control, whether an overlay is blocking it, and which view/controller owns the matched node.

### Verify the Current Page

Problem: a script needs to assert which business page is visible without relying on screenshots or brittle text matching.

Use:

```sh
lookinctl -s com.example.app shell lookin current-vc -o current-vc.json
```

This separates likely business view controllers from overlay/debug/system controllers, making page attribution easier for automated checks.

### Inspect Runtime UI State

Problem: a UI looks wrong, but it is unclear whether the issue comes from frame, alpha, hidden state, image content, gesture state, or custom Lookin attributes.

Use:

```sh
lookinctl -s com.example.app shell lookin attrs <layer-oid> -o attrs.json
lookinctl -s com.example.app shell lookin details <oid> --attrs need --basis --subitems -o detail.json
lookinctl -s com.example.app shell lookin image <image-view-oid> -o image.png
```

This gives scriptable access to the same runtime information that is usually inspected manually in Lookin.

### Try Safe Runtime Changes

Problem: a developer wants to quickly test whether a property or recognizer state explains a UI issue.

Use:

```sh
lookinctl -s com.example.app shell lookin set-builtin <oid> setHidden: bool true
lookinctl -s com.example.app shell lookin set-builtin <oid> setAlpha: float 0.5
lookinctl -s com.example.app shell lookin recognizer <recognizer-oid> disable
lookinctl -s com.example.app shell lookin patch <oid> --screenshot group -o patch.json
```

This helps confirm hypotheses without rebuilding the app. Use it only in debug builds that include LookinServer.

### Run Agent-Friendly UI Diagnostics

Problem: an AI agent or script needs deterministic, file-based app introspection instead of a visual macOS workflow.

Use:

```sh
lookinctl devices --json
lookinctl -s <target> shell lookin app -o app.json
lookinctl -s <target> shell lookin current-vc -o current-vc.json
lookinctl -s <target> shell uiautomator dump -o hierarchy.json
```

The outputs are JSON or image files, so they can be consumed by CI, automation tools, or follow-up analysis scripts.

## Practical Skills

### Find the Right Command

Use help topics when writing scripts or onboarding a new machine:

```sh
lookinctl help
lookinctl help shell input
lookinctl help shell lookin
```

`help` does not require a connected app. Command-specific `--help` also works:

```sh
lookinctl devices --help
lookinctl -s com.example.app shell input --help
```

### Find Connected Apps

Use this first to get the target selector for later commands.

```sh
lookinctl devices
lookinctl devices --json
```

Typical output:

```text
usb:3:47177  device index:0 transport:usb app:"Demo Debug" bundle:com.example.app
```

Then use any of these as `-s`:

```sh
lookinctl -s usb:3:47177 ...
lookinctl -s com.example.app ...
lookinctl -s 0 ...
```

### Capture Current Screen

High-quality screenshot, suitable for coordinate picking:

```sh
lookinctl -s com.example.app shell screencap -p -o screen.png
```

Low-resolution LookinServer preview image:

```sh
lookinctl -s com.example.app shell screencap -p --preview -o preview.png
```

Coordinates for `shell input tap` are screenshot pixels by default. On a 3x device, `585 933` maps to UIKit point `195 311`.

### Find Current View Controller

Get the likely current business view controller and separate overlay/debug controllers.

```sh
lookinctl -s com.example.app shell lookin current-vc
lookinctl -s com.example.app shell lookin current-vc -o current-vc.json
```

The output includes:

- `current`: best business VC candidate.
- `businessCandidates`: non-overlay VC candidates.
- `overlays`: system/debug windows such as keyboard, FLEX, tracker overlays.

### Dump View Hierarchy

adb-style:

```sh
lookinctl -s com.example.app shell uiautomator dump -o hierarchy.json
```

Lookin-style:

```sh
lookinctl -s com.example.app shell lookin hierarchy -o hierarchy.json
lookinctl -s com.example.app shell lookin hierarchy --max-depth 4 -o shallow.json
```

The JSON includes view/layer oid, frame, bounds, class chain, event handlers, host view controller, and child nodes.

### Inspect a Coordinate Before Tapping

Use hit-test to see what a coordinate would target. This does not trigger UI.

```sh
lookinctl -s com.example.app shell input hit-test 585 933
lookinctl -s com.example.app shell input hit-test 195 311 --points
```

The result includes:

- `hit`: topmost matched view.
- `matches`: other candidates under the same coordinate.
- `path`: matched ancestry.
- `input`: raw pixel coordinate and converted UIKit point.

This is useful when full-screen watermark/debug views sit above the actual UI.

### Try a Semantic Tap

Best-effort activation from coordinates:

```sh
lookinctl -s com.example.app shell input tap 585 933
lookinctl -s com.example.app shell input tap 585 933 --dry-run
```

What it does:

- Finds candidate views under the coordinate.
- Skips through non-actionable overlays when possible.
- Tries `sendActionsForControlEvents:UIControlEventTouchUpInside` on `UIControl`.
- Falls back to `accessibilityActivate`.

This is not physical `UITouch` injection. It works well for many buttons and accessibility-backed controls, but custom gesture views may need a LookinServer input extension or WDA.

Failure is explicit and machine-readable:

```json
{
  "ok": false,
  "code": "NO_ACTIONABLE_TARGET",
  "reason": "Matched views, but none of the candidates is an actionable UIControl and no candidate could be activated semantically.",
  "suggestion": "Run input hit-test on this coordinate, choose a different point inside a UIControl/accessibility element, or add native input support to LookinServer for this custom view."
}
```

Common failure codes:

- `NO_HIT`: no view matched the coordinate.
- `NO_ACTIONABLE_TARGET`: views matched, but none can be semantically activated.
- `ACTION_FAILED`: activation was attempted but failed or returned false.
- `HIERARCHY_REQUEST_FAILED`: hierarchy request failed, often because the app is backgrounded or the single LookinServer connection is occupied.
- `UNEXPECTED_HIERARCHY_RESPONSE`: protocol response type mismatch.

### Inspect Attributes

Fetch all attribute groups for a layer oid:

```sh
lookinctl -s com.example.app shell lookin attrs 1 -o attrs.json
```

Fetch detailed info for one or more display items:

```sh
lookinctl -s com.example.app shell lookin details 1 --attrs need --basis --subitems -o detail.json
lookinctl -s com.example.app shell lookin details 1,2,3 --screenshot group -o details.json
```

### Invoke a No-Argument Method

```sh
lookinctl -s com.example.app shell lookin invoke 2 description
lookinctl -s com.example.app shell lookin invoke 2 accessibilityActivate
```

LookinServer only supports no-argument selector invocation through this request. Methods with arguments need purpose-built commands or a LookinServer extension.

### Query Selectors and Objects

```sh
lookinctl -s com.example.app shell lookin selectors UIWindow -o selectors.json
lookinctl -s com.example.app shell lookin selectors UIViewController --has-arg
lookinctl -s com.example.app shell lookin object 2 -o object.json
```

### Fetch ImageView Image

```sh
lookinctl -s com.example.app shell lookin image 1984 -o image.png
```

The oid must point to a `UIImageView`.

### Modify Runtime State

Built-in attribute modification:

```sh
lookinctl -s com.example.app shell lookin set-builtin 123 setHidden: bool true
lookinctl -s com.example.app shell lookin set-builtin 123 setAlpha: float 0.5
```

Custom Lookin attribute modification:

```sh
lookinctl -s com.example.app shell lookin set-custom <customSetterID> string "new value"
```

Gesture recognizer enable/disable:

```sh
lookinctl -s com.example.app shell lookin recognizer 456 disable
lookinctl -s com.example.app shell lookin recognizer 456 enable
```

Patch screenshots/details after modification:

```sh
lookinctl -s com.example.app shell lookin patch 1 --screenshot group -o patch.json
```

## Develop

Long-form Chinese maintenance documentation lives in [`../Docs/lookinctl使用与维护.md`](../Docs/lookinctl使用与维护.md).

Requirements:

- macOS with Xcode Command Line Tools.
- `git` for fetching LookinServer protocol sources when this repository does not already contain `Pods/LookinShared`.
- `node` and `npm` only when building the npm package.
- An iOS app that has integrated LookinServer and is currently running.

Useful development loop:

```sh
# Build the local debug/release binary into Build/lookinctl/lookinctl.
LookinCLI/build.sh

# Verify the binary can start.
Build/lookinctl/lookinctl --version

# Verify a connected LookinServer app.
Build/lookinctl/lookinctl devices
Build/lookinctl/lookinctl -s <bundle-id> shell lookin current-vc
Build/lookinctl/lookinctl -s <bundle-id> shell uiautomator dump -o hierarchy.json
```

The CLI is intentionally independent from `Lookin.app`. Runtime protocol code is compiled from `LookinShared` and Peertalk-compatible sources, then linked into a single native command.

When changing command behavior, prefer adding or updating the matching practical command in this README. The README doubles as the operator-facing skill list for agents and humans.

## Build

Build for the current Mac architecture:

```sh
LookinCLI/build.sh
```

Build a universal binary for Apple Silicon and Intel Macs:

```sh
LOOKINCTL_ARCHS="arm64 x86_64" LookinCLI/build.sh
lipo -archs Build/lookinctl/lookinctl
```

Install a local build:

```sh
LOOKINCTL_INSTALL_DIR=/usr/local/bin LookinCLI/install.sh
lookinctl --version
```

Signing behavior:

- By default `build.sh` ad-hoc signs the binary and verifies it with `codesign --verify --strict`.
- Ad-hoc signing does not require a certificate and does not expire.
- Set `LOOKINCTL_CODESIGN=0` to skip signing for local debugging.
- Set `LOOKINCTL_CODESIGN_IDENTITY` and `LOOKINCTL_CODESIGN_OPTIONS` when your distribution policy requires a specific signing identity.

```sh
LOOKINCTL_ARCHS="arm64 x86_64" \
LOOKINCTL_CODESIGN_IDENTITY="<codesign-identity>" \
LOOKINCTL_CODESIGN_OPTIONS="--timestamp --options runtime" \
LookinCLI/build.sh
```

## Publish

`lookinctl` can be published as an independent npm package. The npm package contains a small Node.js wrapper plus the native macOS binary, so users do not need `Lookin.app` or Xcode after installation.

Create a universal macOS tarball:

```sh
LOOKINCTL_ARCHS="arm64 x86_64" \
LookinCLI/package-npm.sh --name @your-scope/lookinctl --registry https://npm.example.com
```

Publish to an npm registry:

```sh
LOOKINCTL_ARCHS="arm64 x86_64" \
LookinCLI/package-npm.sh \
  --name @your-scope/lookinctl \
  --registry https://npm.example.com \
  --publish
```

Signing behavior:

- `build.sh` ad-hoc signs the binary by default and verifies it with `codesign --verify --strict`.
- ad-hoc signing does not require a certificate and does not expire.
- The npm wrapper and `postinstall` remove `com.apple.quarantine` from the bundled binary when possible.
- If your distribution policy requires a specific signing identity, set `LOOKINCTL_CODESIGN_IDENTITY` before packaging.

```sh
LOOKINCTL_ARCHS="arm64 x86_64" \
LOOKINCTL_CODESIGN_IDENTITY="<codesign-identity>" \
LOOKINCTL_CODESIGN_OPTIONS="--timestamp --options runtime" \
LookinCLI/package-npm.sh --name @your-scope/lookinctl --publish
```

Recommended release flow:

```sh
# 1. Build and smoke-test locally.
LOOKINCTL_ARCHS="arm64 x86_64" LookinCLI/build.sh
Build/lookinctl/lookinctl devices

# 2. Create the package tarball.
LOOKINCTL_ARCHS="arm64 x86_64" \
LookinCLI/package-npm.sh --name @your-scope/lookinctl --registry https://npm.example.com

# 3. Publish after verifying package contents.
tar -tf Build/lookinctl-npm/tarballs/*.tgz
LOOKINCTL_ARCHS="arm64 x86_64" \
LookinCLI/package-npm.sh --name @your-scope/lookinctl --registry https://npm.example.com --publish
```

### npm Artifact Layout

The npm source template and generated artifacts have fixed locations:

```text
LookinCLI/npm/                       npm package source template, committed.
Build/lookinctl-npm/package/         generated package directory before packing.
Build/lookinctl-npm/tarballs/        generated installable .tgz files.
Build/lookinctl-npm/manifest.json    machine-readable metadata for CI/upload scripts.
```

`package-npm.sh` clears and recreates `Build/lookinctl-npm/package/` and `Build/lookinctl-npm/tarballs/` on each run. Upload scripts should read `Build/lookinctl-npm/manifest.json` or pick the tarball from `Build/lookinctl-npm/tarballs/`; they should not depend on files inside `LookinCLI/npm/`.

CI:

- `LookinCLI/ci-publish.example.yml` is a template for publishing from a macOS CI runner.
- Set npm auth in CI with your registry token.
- Keep the package repository source-based if future CLI changes should be reviewed there.

## Directory Structure

```text
LookinCLI/
  README.md                  Operator, developer, build, and release guide.
  main.m                     Standalone Objective-C CLI implementation.
  build.sh                   Native build script for local and universal binaries.
  install.sh                 Local/source/release installer.
  package-npm.sh             Builds and publishes the npm distribution.
  ci-publish.example.yml     CI npm publish pipeline template.
  npm/
    package.json             npm package template.
    README.md                README shipped inside the npm package.
    .npmrc.example           Registry auth example.
    bin/lookinctl.js         Node wrapper that launches the bundled native binary.
    scripts/postinstall.js   chmod, quarantine cleanup, and codesign verification.
```

Generated artifacts are intentionally kept out of source control:

```text
Build/lookinctl/                    Native build output and fetched protocol sources.
Build/lookinctl-npm/package/        Staged npm package.
Build/lookinctl-npm/tarballs/       Generated npm tarballs.
Build/lookinctl-npm/manifest.json   Artifact metadata for CI/upload scripts.
```

Design boundaries:

- `main.m` owns command parsing, LookinServer request/response handling, adb-like output, and semantic input behavior.
- `build.sh` owns dependency discovery, optional LookinServer source fetch, architecture selection, linking, and signing.
- `npm/bin/lookinctl.js` stays thin: it only finds the bundled binary, prepares execution permissions, clears quarantine when possible, and forwards arguments.
- The npm package ships build artifacts, but this repository keeps editable source so later protocol or command changes are reviewable.

## Protocol Coverage

`lookinctl` exposes every LookinServer request type in protocol version 7:

- `Ping`, `App`, `Hierarchy`
- `HierarchyDetails`, `AttrModificationPatch`
- `InbuiltAttrModification`, `CustomAttrModification`
- `InvokeMethod`, `FetchObject`, `FetchImageViewImage`
- `ModifyRecognizerEnable`
- `AllAttrGroups`, `AllSelectorNames`
- `CancelHierarchyDetails`

LookinServer does not expose physical adb `input tap` style event injection. `shell input tap` is a semantic approximation built from existing protocol abilities.
