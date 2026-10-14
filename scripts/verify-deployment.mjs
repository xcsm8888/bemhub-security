import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import path from "node:path";

const root = path.resolve(import.meta.dirname, "..");
const endpoint = process.env.DEPLOYMENT_RPC_URL;
if (!endpoint) throw new Error("DEPLOYMENT_RPC_URL is required and is never printed or stored");

let requestId = 0;
async function call(method, params = []) {
  const response = await fetch(endpoint, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: ++requestId, method, params }),
  });
  const body = await response.json();
  if (!response.ok || body.error) throw new Error(`chain request failed: ${method}`);
  return body.result;
}

const deployment = JSON.parse(await readFile(path.join(root, "market", "deployments", "bsc-56.json"), "utf8"));
const build = JSON.parse(await readFile(path.join(root, "market", "build", "solc-output.json"), "utf8"));
const chainId = Number.parseInt(await call("eth_chainId"), 16);
if (chainId !== deployment.chainId) throw new Error(`unexpected chain id: ${chainId}`);

const treasury = deployment.contracts.BemHubFeeTreasury.address.slice(2).toLowerCase().padStart(64, "0");
const results = [];
for (const [name, record] of Object.entries(deployment.contracts)) {
  const artifact = build.contracts[`${name}.sol`][name];
  let compiled = artifact.evm.deployedBytecode.object.toLowerCase();
  for (const entries of Object.values(artifact.evm.deployedBytecode.immutableReferences)) {
    for (const ref of entries) {
      const start = ref.start * 2;
      compiled = compiled.slice(0, start) + treasury + compiled.slice(start + ref.length * 2);
    }
  }
  const onchain = (await call("eth_getCode", [record.address, "latest"])).slice(2).toLowerCase();
  const sha256 = createHash("sha256").update(Buffer.from(onchain, "hex")).digest("hex");
  results.push({
    contract: name,
    address: record.address,
    runtimeBytes: onchain.length / 2,
    hashMatches: sha256 === record.runtimeBytecodeSha256,
    compiledMatch: onchain === compiled,
  });
}

process.stdout.write(`${JSON.stringify({ chainId, contracts: results }, null, 2)}\n`);
if (results.some((item) => !item.hashMatches || !item.compiledMatch)) process.exitCode = 1;
