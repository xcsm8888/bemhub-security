import { readdir, readFile, stat } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const RULES = [
  ["private-key", /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|(?:PRIVATE_KEY|SECRET_KEY)\s*[:=]\s*["']?(?:0x)?[0-9a-f]{64}\b/i],
  ["rpc-endpoint", /(?:[A-Z0-9_]*RPC[A-Z0-9_]*\s*[:=]\s*["']?https?:\/\/\S+|https?:\/\/[^\s"'`]*(?:bsc-data\s*seed|dataseed|quiknode|alchemy|infura|ankr|llamarpc|drpc|nodereal|chainstack|blastapi|getblock|rpc\.)[^\s"'`]*)/i],
  ["ipv4-address", /\b(?:25[0-5]|2[0-4]\d|1?\d?\d)(?:\.(?:25[0-5]|2[0-4]\d|1?\d?\d)){3}\b/],
  ["windows-private-path", /\b[A-Za-z]:[\\/][^\s"'`]+/i],
  ["local-file-uri", /file:\/\/[^\s"'`]+/i],
  ["server-private-path", /\/(?:srv|root|home)\/[A-Za-z0-9._/-]+/],
  ["credential-assignment", /(?:API_HASH|API_KEY|ACCESS_TOKEN|AUTH_TOKEN|PASSWORD|SECRET)\s*[:=]\s*["']?[A-Za-z0-9_+\/=.-]{20,}/i],
  ["telegram-session", /(?:telegram[_ -]?session|session)\s*[:=]\s*["']?(?:1AZQ|[A-Za-z0-9_-]{32,})/i],
];

export function scanText(file, text) {
  const findings = [];
  const lines = text.split(/\r?\n/);
  for (let index = 0; index < lines.length; index += 1) {
    for (const [category, pattern] of RULES) {
      if (pattern.test(lines[index])) findings.push({ file, line: index + 1, category });
    }
  }
  return findings;
}

const SKIP_DIRS = new Set([".git", "node_modules", "build", "out", "cache"]);
const BINARY_EXTENSIONS = new Set([".png", ".jpg", ".jpeg", ".gif", ".ico", ".woff", ".woff2", ".zip", ".gz", ".pdf"]);

async function listFiles(root, current = root) {
  const files = [];
  for (const entry of await readdir(current, { withFileTypes: true })) {
    if (SKIP_DIRS.has(entry.name)) continue;
    const absolute = path.join(current, entry.name);
    const relative = path.relative(root, absolute).replaceAll("\\", "/");
    if (relative === "market/lib" || relative.startsWith("market/lib/")) continue;
    if (entry.isDirectory()) files.push(...await listFiles(root, absolute));
    else if (entry.isFile() && !BINARY_EXTENSIONS.has(path.extname(entry.name).toLowerCase())) files.push(absolute);
  }
  return files;
}

export async function scanDirectory(root) {
  const findings = [];
  for (const absolute of await listFiles(root)) {
    if ((await stat(absolute)).size > 2_000_000) continue;
    const relative = path.relative(root, absolute).replaceAll("\\", "/");
    findings.push(...scanText(relative, await readFile(absolute, "utf8")));
  }
  return findings;
}

async function runCli() {
  const root = path.resolve(process.argv[2] ?? ".");
  const findings = await scanDirectory(root);
  if (findings.length) {
    for (const finding of findings) process.stderr.write(`${finding.file}:${finding.line} [${finding.category}]\n`);
    process.stderr.write(`Blocked: ${findings.length} potential secret or infrastructure reference(s).\n`);
    process.exitCode = 1;
  } else {
    process.stdout.write("Secret/privacy scan passed: 0 findings.\n");
  }
}

const currentFile = fileURLToPath(import.meta.url);
if (process.argv[1] && path.resolve(process.argv[1]) === currentFile) await runCli();
