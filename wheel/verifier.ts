import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { 承诺种子, 生成开奖结果 } from "./source/fairness";

type WheelProof = {
  roundId: string;
  paytableVersion: string;
  aggregateHash: string;
  seedRevealHex: string;
  seedCommit: string;
  result: unknown;
};

export type WheelVerification = {
  commitmentMatches: boolean;
  resultMatches: boolean;
  valid: boolean;
};

function isHex(value: unknown, bytes: number): value is string {
  return typeof value === "string" && new RegExp(`^[0-9a-f]{${bytes * 2}}$`, "i").test(value);
}

function isProof(value: unknown): value is WheelProof {
  if (!value || typeof value !== "object") return false;
  const proof = value as Partial<WheelProof>;
  return typeof proof.roundId === "string" && proof.roundId.length > 0
    && typeof proof.paytableVersion === "string" && proof.paytableVersion.length > 0
    && isHex(proof.aggregateHash, 32)
    && isHex(proof.seedRevealHex, 32)
    && isHex(proof.seedCommit, 32)
    && proof.result !== undefined;
}

export function verifyWheelProof(value: unknown): WheelVerification {
  const invalid = { commitmentMatches: false, resultMatches: false, valid: false };
  if (!isProof(value)) return invalid;
  try {
    const seed = Buffer.from(value.seedRevealHex, "hex");
    const commitmentMatches = 承诺种子(seed) === value.seedCommit.toLowerCase();
    const expected = 生成开奖结果({
      服务端种子: seed,
      轮次ID: value.roundId,
      聚合摘要: value.aggregateHash.toLowerCase(),
      赔率版本: value.paytableVersion,
    });
    const resultMatches = JSON.stringify(expected) === JSON.stringify(value.result);
    return { commitmentMatches, resultMatches, valid: commitmentMatches && resultMatches };
  } catch {
    return invalid;
  }
}

async function runCli() {
  const proofPath = process.argv[2];
  if (!proofPath) throw new Error("usage: npx tsx wheel/verifier.ts <proof.json>");
  const proof = JSON.parse(await readFile(path.resolve(proofPath), "utf8"));
  const verification = verifyWheelProof(proof);
  process.stdout.write(`${JSON.stringify(verification, null, 2)}\n`);
  process.exitCode = verification.valid ? 0 : 1;
}

const currentFile = fileURLToPath(import.meta.url);
if (process.argv[1] && path.resolve(process.argv[1]) === currentFile) {
  await runCli();
}
