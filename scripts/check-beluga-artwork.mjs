#!/usr/bin/env node
// Pins the supplied Beluga artwork and its approved opaque iOS exports. Artifact inspection separately
// verify that each compiled app actually includes and selects its icon.
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";

const root = path.resolve(process.argv[2] ?? ".");
const catalog = "iOS/opensteamer/Sources/Assets.xcassets/AppIcon.appiconset";
const approvedImages = [
  [{"filename": "Icon-20@2x.png", "idiom": "iphone", "scale": "2x", "size": "20x20"}, 40, "8064b0fea86aa0f7088737ac6946a7cba1fef1b0b53d6afa90f9f1c1dfc5d0df"],
  [{"filename": "Icon-20@3x.png", "idiom": "iphone", "scale": "3x", "size": "20x20"}, 60, "c8db1e313d974287da7a9dfa33c5a0d7d805bfa910e43465c68da04424532360"],
  [{"filename": "Icon-29@2x.png", "idiom": "iphone", "scale": "2x", "size": "29x29"}, 58, "15dce69fa397a060e6fa03ff8ac16bbe76a46cfb2073a8bdd50d3d0e2d6b96f7"],
  [{"filename": "Icon-29@3x.png", "idiom": "iphone", "scale": "3x", "size": "29x29"}, 87, "17e7a111e519eccd148d334f6ba9266cec4f7a50b0feb04352179f458bd1cd21"],
  [{"filename": "Icon-40@2x.png", "idiom": "iphone", "scale": "2x", "size": "40x40"}, 80, "88ca99938e815d26ffec1ea96e299bacfc4e2373b6d76e48b0ffd1abbd3af8e7"],
  [{"filename": "Icon-40@3x.png", "idiom": "iphone", "scale": "3x", "size": "40x40"}, 120, "b3427c44f9212b8a6f3a394af9a73bfe5d2c85df1155aff639d834a38d970718"],
  [{"filename": "Icon-60@2x.png", "idiom": "iphone", "scale": "2x", "size": "60x60"}, 120, "b3427c44f9212b8a6f3a394af9a73bfe5d2c85df1155aff639d834a38d970718"],
  [{"filename": "Icon-60@3x.png", "idiom": "iphone", "scale": "3x", "size": "60x60"}, 180, "b508569e35232c16ed5ca13daa9f9a029f85967c98c30bfa57e3a25f95d7693a"],
  [{"filename": "Icon-1024.png", "idiom": "ios-marketing", "scale": "1x", "size": "1024x1024"}, 1024, "68adc2fab0db35038f845b3da9e24adc995b7357887b39105ebb53aea6ca0ccc"],
];
function requireFile(relative) {
  const file = path.join(root, relative);
  if (!fs.lstatSync(file).isFile()) throw new Error(`artwork must be a regular file: ${relative}`);
  return fs.readFileSync(file);
}
function verifyDigest(relative, digest) {
  const bytes = requireFile(relative);
  if (crypto.createHash("sha256").update(bytes).digest("hex") !== digest) {
    throw new Error(`approved Beluga artwork differs: ${relative}`);
  }
  return bytes;
}
try {
  verifyDigest("branding/BelugaLogo.png", "09a4b0ac359c28eae7c9085ef27222bbdde2426f420e70ca76b5fce38ceea88b");
  verifyDigest("macOS/BelugaHost/Resources/AppIcon.icns", "b2b23a101dc2de171d4a64eec31afc87858d8c31515048f958d82ed2e779f936");
  const contents = JSON.parse(requireFile(`${catalog}/Contents.json`));
  if (!Array.isArray(contents.images) || contents.images.length !== approvedImages.length) {
    throw new Error("Beluga app icon catalog has the wrong image set");
  }
  for (const [expected, dimension, digest] of approvedImages) {
    const actual = contents.images.find((entry) => entry.filename === expected.filename);
    if (!actual || Object.keys(actual).length !== Object.keys(expected).length ||
        Object.entries(expected).some(([key, value]) => actual[key] !== value)) {
      throw new Error(`Beluga app icon catalog mapping differs: ${expected.filename}`);
    }
    const bytes = verifyDigest(`${catalog}/${expected.filename}`, digest);
    if (bytes.subarray(0, 8).toString("hex") !== "89504e470d0a1a0a" ||
        bytes.readUInt32BE(16) !== dimension || bytes.readUInt32BE(20) !== dimension ||
        bytes[24] !== 8 || bytes[25] !== 2) {
      throw new Error(`Beluga iOS icon must be opaque RGB at ${dimension}px: ${expected.filename}`);
    }
  }
  console.log("Beluga artwork source check passed");
} catch (error) {
  console.error(`Beluga artwork source check failed: ${error.message}`);
  process.exit(1);
}
