import { createHash } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import solc from "solc";

const root = path.resolve(import.meta.dirname, "..");
const sourceDir = path.join(root, "market", "src");
const contractNames = ["BemHubBase.sol", "BemHubFeeTreasury.sol", "BemHubCircuitMarket.sol", "BemHubMaterialMarket.sol"];
const sources = Object.fromEntries(await Promise.all(contractNames.map(async (name) => [name, { content: await readFile(path.join(sourceDir, name), "utf8") }])));

const input = {
  language: "Solidity",
  sources,
  settings: {
    optimizer: { enabled: true, runs: 10_000 },
    evmVersion: "shanghai",
    metadata: { bytecodeHash: "none", appendCBOR: false },
    outputSelection: { "*": { "*": ["abi", "evm.bytecode.object", "evm.deployedBytecode.object", "evm.deployedBytecode.immutableReferences"] } },
  },
};

const output = JSON.parse(solc.compile(JSON.stringify(input)));
const errors = (output.errors ?? []).filter((item) => item.severity === "error");
if (errors.length) {
  for (const error of errors) process.stderr.write(`${error.formattedMessage}\n`);
  process.exit(1);
}

const targetNames = ["BemHubFeeTreasury", "BemHubCircuitMarket", "BemHubMaterialMarket"];
const hashes = {};
for (const name of targetNames) {
  const contract = output.contracts[`${name}.sol`][name];
  const runtime = contract.evm.deployedBytecode.object;
  hashes[name] = {
    creationBytecodeSha256: createHash("sha256").update(Buffer.from(contract.evm.bytecode.object, "hex")).digest("hex"),
    runtimeBytecodeSha256: createHash("sha256").update(Buffer.from(runtime, "hex")).digest("hex"),
    runtimeBytes: runtime.length / 2,
    immutableReferences: contract.evm.deployedBytecode.immutableReferences,
  };
}

const artifact = {
  compiler: solc.version(),
  settings: { optimizer: true, optimizerRuns: 10_000, evmVersion: "shanghai", bytecodeHash: "none", cborMetadata: false },
  contracts: hashes,
};
const expectedPath = path.join(root, "market", "compiled-bytecode-sha256.json");
const serialized = `${JSON.stringify(artifact, null, 2)}\n`;
if (process.argv.includes("--write")) {
  await writeFile(expectedPath, serialized, "utf8");
  process.stdout.write("Wrote market/compiled-bytecode-sha256.json\n");
} else {
  const expected = await readFile(expectedPath, "utf8").catch(() => null);
  if (expected !== serialized) {
    process.stderr.write("Compiled market bytecode differs from the committed snapshot.\n");
    process.exit(1);
  }
  process.stdout.write("Market compile passed: 3 contracts match committed bytecode hashes.\n");
}

const buildDir = path.join(root, "market", "build");
await mkdir(buildDir, { recursive: true });
await writeFile(path.join(buildDir, "solc-output.json"), `${JSON.stringify(output)}\n`, "utf8");
