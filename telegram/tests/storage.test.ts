import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import test from "node:test";
import {
  createTelegramSessionVault,
  telegramVaultKeys,
  type TelegramSessionVaultBackend,
} from "../source/storage.ts";

const WALLET_A = "0x1111111111111111111111111111111111111111";
const WALLET_B = "0x2222222222222222222222222222222222222222";
const FIXTURE_VALUE = ["PUBLIC_TEST_", "VALUE_NOT_REAL"].join("");

class MemoryBackend implements TelegramSessionVaultBackend {
  readonly values = new Map<string, unknown>();
  failPut: ((key: string, value: unknown) => boolean) | null = null;
  async get(key: string) { return this.values.get(key); }
  async put(key: string, value: unknown) {
    if (this.failPut?.(key, value)) throw new Error("persistence rejected");
    this.values.set(key, value);
  }
  async delete(key: string) { this.values.delete(key); }
  async keys() { return [...this.values.keys()]; }
}

function create(backend: TelegramSessionVaultBackend | null = new MemoryBackend(), crypto: Crypto | null = webcrypto as unknown as Crypto) {
  return createTelegramSessionVault({ backend, crypto, now: () => 1_760_000_000_000 });
}

test("AES-GCM round-trip never persists plaintext", async () => {
  const backend = new MemoryBackend();
  const vault = create(backend);
  assert.equal(await vault.save(WALLET_A, FIXTURE_VALUE), "persisted");
  assert.equal(await vault.read(WALLET_A), FIXTURE_VALUE);
  assert.equal(JSON.stringify([...backend.values.entries()]).includes(FIXTURE_VALUE), false);
});

test("wallet binding rejects a copied ciphertext and removes it", async () => {
  const backend = new MemoryBackend();
  const vault = create(backend);
  const a = telegramVaultKeys(WALLET_A)!;
  const b = telegramVaultKeys(WALLET_B)!;
  await vault.save(WALLET_A, FIXTURE_VALUE);
  backend.values.set(b.record, backend.values.get(a.record));
  backend.values.set(b.cryptoKey, backend.values.get(a.cryptoKey));
  assert.equal(await vault.read(WALLET_B), null);
  assert.equal(backend.values.has(b.record), false);
  assert.equal(backend.values.has(b.cryptoKey), false);
});

test("falls back to memory only when durable storage is unavailable", async () => {
  const vault = create(null);
  assert.equal(await vault.save(WALLET_A, FIXTURE_VALUE), "memory-only");
  assert.equal(await vault.read(WALLET_A), FIXTURE_VALUE);
});
