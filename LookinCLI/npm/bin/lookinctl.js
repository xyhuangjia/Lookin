#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

function platformArch() {
  if (process.platform !== "darwin") {
    return null;
  }
  if (process.arch === "arm64") {
    return "darwin-arm64";
  }
  if (process.arch === "x64") {
    return "darwin-x64";
  }
  return null;
}

function candidates() {
  const root = path.resolve(__dirname, "..");
  const envBinary = process.env.LOOKINCTL_BINARY;
  const pair = platformArch();
  const values = [];
  if (envBinary) {
    values.push(envBinary);
  }
  if (pair) {
    values.push(path.join(root, "prebuilds", pair, "lookinctl"));
  }
  if (process.platform === "darwin") {
    values.push(path.join(root, "prebuilds", "darwin-universal", "lookinctl"));
  }
  return values;
}

const binary = candidates().find((file) => file && fs.existsSync(file));

if (!binary) {
  console.error("lookinctl native binary was not found for this platform.");
  console.error(`platform=${process.platform} arch=${process.arch}`);
  console.error("Reinstall the package with a matching prebuild, or set LOOKINCTL_BINARY=/absolute/path/to/lookinctl.");
  process.exit(127);
}

try {
  fs.chmodSync(binary, 0o755);
} catch (_) {
}

if (process.platform === "darwin") {
  spawnSync("xattr", ["-d", "com.apple.quarantine", binary], { stdio: "ignore" });
}

const result = spawnSync(binary, process.argv.slice(2), { stdio: "inherit" });
if (result.error) {
  console.error(result.error.message);
  process.exit(126);
}
if (result.signal) {
  process.kill(process.pid, result.signal);
}
process.exit(result.status === null ? 1 : result.status);
