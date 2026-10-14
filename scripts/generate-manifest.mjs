import { createHash } from "node:crypto";
import { readdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";

const root = path.resolve(import.meta.dirname, "..");
const groups = [
  ["telegram", "telegram/source", [".ts"]],
  ["wheel", "wheel/source", [".ts"]],
  ["wheel", "wheel", ["verifier.ts"]],
  ["market", "market/src", [".sol"]],
  ["market", "market/test", [".sol"]],
  ["market", "market/deployments", [".json"]],
  ["market", "market", ["compiled-bytecode-sha256.json"]],
];

const files = [];
for (const [module, directory, selectors] of groups) {
  const absolute = path.join(root, directory);
  for (const name of await readdir(absolute)) {
    if (!selectors.some((selector) => selector.startsWith(".") ? name.endsWith(selector) : name === selector)) continue;
    const relative = path.posix.join(directory.replaceAll("\\", "/"), name);
    const content = await readFile(path.join(root, relative), "utf8");
    const canonicalText = content.replace(/\r\n/g, "\n");
    files.push({ module, path: relative, sha256: createHash("sha256").update(canonicalText, "utf8").digest("hex") });
  }
}
files.sort((a, b) => a.path.localeCompare(b.path));
const manifest = {
  schemaVersion: 1,
  release: "bemhub-security-2026-10-14",
  generatedAt: "2026-10-14",
  license: "MIT",
  thirdPartyAudit: false,
  files,
};
const manifestPath = path.join(root, "MANIFEST.json");
const serialized = `${JSON.stringify(manifest, null, 2)}\n`;
if (process.argv.includes("--write")) {
  await writeFile(manifestPath, serialized, "utf8");
  process.stdout.write(`Wrote MANIFEST.json with ${files.length} curated file hashes.\n`);
} else {
  const expected = await readFile(manifestPath, "utf8").catch(() => null);
  if (expected !== serialized) {
    process.stderr.write("MANIFEST.json differs from the curated public files.\n");
    process.exit(1);
  }
  process.stdout.write(`Manifest passed: ${files.length} curated file hashes match.\n`);
}
