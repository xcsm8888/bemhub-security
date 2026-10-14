import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { verifyWheelProof } from "../wheel/verifier.ts";

test("accepts a proof only when commitment and deterministic result both match", () => {
  const proof = JSON.parse(readFileSync(new URL("../wheel/vectors/public-example.json", import.meta.url), "utf8"));

  assert.deepEqual(verifyWheelProof(proof), {
    commitmentMatches: true,
    resultMatches: true,
    valid: true,
  });
  assert.equal(verifyWheelProof({ ...proof, aggregateHash: "f".repeat(64) }).valid, false);
});

test("rejects malformed proof fields without throwing", () => {
  assert.deepEqual(verifyWheelProof({ roundId: "" }), {
    commitmentMatches: false,
    resultMatches: false,
    valid: false,
  });
});
