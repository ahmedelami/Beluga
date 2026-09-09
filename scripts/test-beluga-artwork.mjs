#!/usr/bin/env node
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "beluga-artwork-tests-"));
const catalog = "iOS/opensteamer/Sources/Assets.xcassets/AppIcon.appiconset";
let rejected = 0;
function run() {
  return spawnSync(process.execPath, [path.join(root, "scripts/check-beluga-artwork.mjs"), scratch], {
    encoding: "utf8",
  });
}
function mutation(relative, edit, diagnostic) {
  const file = path.join(scratch, relative);
  const original = fs.readFileSync(file);
  try {
    edit(file, Buffer.from(original));
    const result = run();
    assert.equal(result.status, 1, `artwork mutation passed: ${relative}`);
    assert.ok(result.stderr.includes(diagnostic), result.stderr);
    rejected += 1;
  } finally {
    fs.rmSync(file, { force: true });
    fs.writeFileSync(file, original);
  }
}
try {
  for (const relative of ["branding", "macOS/BelugaHost/Resources", catalog]) {
    fs.cpSync(path.join(root, relative), path.join(scratch, relative), { recursive: true });
  }
  const baseline = run();
  assert.equal(baseline.status, 0, baseline.stderr);
  for (const relative of [
    "branding/BelugaLogo.png",
    "macOS/BelugaHost/Resources/AppIcon.icns",
    ...fs.readdirSync(path.join(scratch, catalog)).filter((name) => name.endsWith(".png"))
      .map((name) => `${catalog}/${name}`),
  ]) {
    mutation(relative, (file, bytes) => {
      bytes[bytes.length - 1] ^= 1;
      fs.writeFileSync(file, bytes);
    }, "approved Beluga artwork differs");
  }
  for (const edit of [
    (contents) => contents.images.pop(),
    (contents) => { contents.images[0].filename = contents.images[1].filename; },
    (contents) => { contents.images[0].scale = "3x"; },
  ]) {
    mutation(`${catalog}/Contents.json`, (file, bytes) => {
      const contents = JSON.parse(bytes);
      edit(contents);
      fs.writeFileSync(file, JSON.stringify(contents));
    }, "Beluga app icon catalog");
  }
  mutation("branding/BelugaLogo.png", (file) => {
    fs.unlinkSync(file);
    fs.symlinkSync(path.join(root, "branding/BelugaLogo.png"), file);
  }, "artwork must be a regular file");
  assert.equal(run().status, 0, "mutations did not restore the artwork baseline");
  console.log(`Beluga artwork baseline and ${rejected} negative mutations passed`);
} finally {
  fs.rmSync(scratch, { recursive: true, force: true });
}
