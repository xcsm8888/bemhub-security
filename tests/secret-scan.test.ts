import assert from "node:assert/strict";
import test from "node:test";
import { scanText } from "../scripts/secret-scan.mjs";

test("allows public contracts, source hashes, and ordinary documentation", () => {
  const findings = scanText("README.md", [
    "BSC chain id: 56",
    "contract: 0x2D2f8D87f6Db449A61Eef8Dd61daF9Cc3a165C35",
    "sha256: 40b45fe58bae6639b9d790875c779ec8792a97e3",
    "Documentation: https://github.com/xcsm8888/bemhub-security",
  ].join("\n"));
  assert.deepEqual(findings, []);
});

test("blocks RPC data, infrastructure paths, secrets, and Telegram sessions", () => {
  const fixtures = [
    ["RPC", "_URL=", "https://", "rpc.", "example.invalid/key-value"].join(""),
    ["https://", "bsc-data", "seed.example.invalid"].join(""),
    ["server=203", ".0.113", ".9"].join(""),
    ["C:", "\\", "Users", "\\", "Example", "\\", "secret.txt"].join(""),
    ["/", "srv", "/private-app/shared/config"].join(""),
    ["PRIVATE", "_KEY=", "a".repeat(64)].join(""),
    ["session=", "1AZQ-", "public-test-session-material-should-be-blocked"].join(""),
  ];
  for (const fixture of fixtures) {
    assert.ok(scanText("fixture.txt", fixture).length > 0, `expected blocked fixture: ${fixture.slice(0, 20)}`);
  }
});
