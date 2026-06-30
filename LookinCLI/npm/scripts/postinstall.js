"use strict";

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

const root = path.resolve(__dirname, "..");
const dirs = ["darwin-arm64", "darwin-x64", "darwin-universal"];

for (const dir of dirs) {
  const binary = path.join(root, "prebuilds", dir, "lookinctl");
  if (fs.existsSync(binary)) {
    fs.chmodSync(binary, 0o755);
    if (process.platform === "darwin") {
      spawnSync("xattr", ["-d", "com.apple.quarantine", binary], { stdio: "ignore" });
      const result = spawnSync("codesign", ["--verify", "--strict", "--verbose=2", binary], { stdio: "ignore" });
      if (result.status !== 0) {
        console.warn(`lookinctl: codesign verification failed for ${binary}`);
      }
    }
  }
}
