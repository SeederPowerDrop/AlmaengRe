#!/usr/bin/env node
"use strict";

// Export whole SVG annotation documents. Original JPEGs remain embedded in the
// SVG unchanged; this renderer never opens or modifies the screenshot sources.
const fs = require("node:fs/promises");
const path = require("node:path");
const crypto = require("node:crypto");
const sharp = require("sharp"); // Resolve normally, or through NODE_PATH.

const hash = (bytes) => crypto.createHash("sha256").update(bytes).digest("hex");

async function main() {
  const [directory, ...identifiers] = process.argv.slice(2);
  if (!directory || !identifiers.length || new Set(identifiers).size !== identifiers.length
      || identifiers.some((value) => !/^[a-z][a-z0-9-]*$/.test(value))) {
    throw new Error("Usage: node render-user-guide-figures.cjs <figure-directory> <figure-id>...");
  }
  sharp.concurrency(1);
  sharp.cache(false);
  const figures = {};
  for (const identifier of identifiers) {
    const svgName = `${identifier}.svg`;
    const pngName = `${identifier}.png`;
    const svg = await fs.readFile(path.join(directory, svgName));
    const temporary = path.join(directory, `${pngName}.tmp`);
    try {
      const info = await sharp(svg, { density: 72, limitInputPixels: 100_000_000 })
        .png({ compressionLevel: 9, adaptiveFiltering: true })
        .toFile(temporary);
      await fs.rename(temporary, path.join(directory, pngName));
      figures[identifier] = {
        svg: svgName, svgSHA256: hash(svg), png: pngName,
        pngSHA256: hash(await fs.readFile(path.join(directory, pngName))),
        width: info.width, height: info.height,
      };
    } finally {
      await fs.rm(temporary, { force: true });
    }
  }
  const manifest = {
    version: 1,
    renderer: {
      file: "scripts/render-user-guide-figures.cjs",
      sha256: hash(await fs.readFile(__filename)),
      sharp: sharp.versions.sharp, vips: sharp.versions.vips,
    },
    figures,
  };
  const temporary = path.join(directory, "render-manifest.json.tmp");
  await fs.writeFile(temporary, JSON.stringify(manifest, null, 2) + "\n");
  await fs.rename(temporary, path.join(directory, "render-manifest.json"));
  console.log(`Rendered ${identifiers.length} SVG documents to PNG.`);
}

main().catch((error) => {
  console.error(`User guide figure rendering failed: ${error.message}`);
  process.exitCode = 1;
});
