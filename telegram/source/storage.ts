const DB_NAME = "bem-deweb";
const DB_VERSION = 2;
const LEGACY_STORE_NAME = "telegram";
const VAULT_STORE_NAME = "telegram-vault-v2";
const LEGACY_SESSION_KEY = "session-v1";
const VAULT_PREFIX = "telegram-vault-v2:";

type PersistedTelegramSession = {
  version: 2;
  wallet: string;
  iv: number[];
  ciphertext: number[];
  createdAt: number;
};

export type TelegramSessionVaultBackend = {
  get(key: string): Promise<unknown>;
  put(key: string, value: unknown): Promise<void>;
  delete(key: string): Promise<void>;
  keys(): Promise<string[]>;
};

export type TelegramSessionVaultDeps = {
  backend: TelegramSessionVaultBackend | null;
  crypto: Crypto | null;
  now?: () => number;
};

export type TelegramSessionVault = {
  save(wallet: string | null | undefined, session: string): Promise<"persisted" | "memory-only">;
  read(wallet: string | null | undefined): Promise<string | null>;
  delete(wallet: string | null | undefined): Promise<void>;
  deleteAll(): Promise<void>;
  clearLegacy(): Promise<void>;
};

function normalizeWallet(value: string | null | undefined): string | null {
  const wallet = String(value ?? "").trim().toLowerCase();
  return /^0x[0-9a-f]{40}$/.test(wallet) ? wallet : null;
}

export function telegramVaultKeys(wallet: string | null | undefined) {
  const normalized = normalizeWallet(wallet);
  if (!normalized) return null;
  return {
    record: `${VAULT_PREFIX}${normalized}:record`,
    cryptoKey: `${VAULT_PREFIX}${normalized}:key`,
  } as const;
}

function isPersistedRecord(value: unknown, wallet: string): value is PersistedTelegramSession {
  const record = value as Partial<PersistedTelegramSession> | null;
  return Boolean(
    record
    && record.version === 2
    && record.wallet === wallet
    && Array.isArray(record.iv)
    && record.iv.length === 12
    && record.iv.every((item) => Number.isInteger(item) && item >= 0 && item <= 255)
    && Array.isArray(record.ciphertext)
    && record.ciphertext.length > 0
    && record.ciphertext.every((item) => Number.isInteger(item) && item >= 0 && item <= 255),
  );
}

export function createTelegramSessionVault(deps: TelegramSessionVaultDeps): TelegramSessionVault {
  const memory = new Map<string, string>();
  const now = deps.now ?? Date.now;

  const removePersisted = async (wallet: string) => {
    const keys = telegramVaultKeys(wallet);
    if (!keys || !deps.backend) return;
    await Promise.allSettled([
      deps.backend.delete(keys.record),
      deps.backend.delete(keys.cryptoKey),
    ]);
  };

  return {
    async save(walletValue, session) {
      const wallet = normalizeWallet(walletValue);
      if (!wallet) return "memory-only";
      memory.set(wallet, session);
      if (!deps.backend || !deps.crypto?.subtle) return "memory-only";
      const keys = telegramVaultKeys(wallet)!;
      try {
        const key = await deps.crypto.subtle.generateKey(
          { name: "AES-GCM", length: 256 },
          false,
          ["encrypt", "decrypt"],
        );
        const iv = deps.crypto.getRandomValues(new Uint8Array(12));
        const additionalData = new TextEncoder().encode(wallet);
        const ciphertext = await deps.crypto.subtle.encrypt(
          { name: "AES-GCM", iv, additionalData },
          key,
          new TextEncoder().encode(session),
        );
        await deps.backend.put(keys.cryptoKey, key);
        await deps.backend.put(keys.record, {
          version: 2,
          wallet,
          iv: [...iv],
          ciphertext: [...new Uint8Array(ciphertext)],
          createdAt: now(),
        } satisfies PersistedTelegramSession);
        return "persisted";
      } catch {
        await removePersisted(wallet);
        return "memory-only";
      }
    },

    async read(walletValue) {
      const wallet = normalizeWallet(walletValue);
      if (!wallet) return null;
      const inMemory = memory.get(wallet);
      if (inMemory !== undefined) return inMemory;
      if (!deps.backend || !deps.crypto?.subtle) return null;
      const keys = telegramVaultKeys(wallet)!;
      try {
        const [recordValue, keyValue] = await Promise.all([
          deps.backend.get(keys.record),
          deps.backend.get(keys.cryptoKey),
        ]);
        if (recordValue == null && keyValue == null) return null;
        if (!isPersistedRecord(recordValue, wallet) || !(keyValue instanceof CryptoKey)) {
          await removePersisted(wallet);
          return null;
        }
        const plaintext = await deps.crypto.subtle.decrypt(
          {
            name: "AES-GCM",
            iv: new Uint8Array(recordValue.iv),
            additionalData: new TextEncoder().encode(wallet),
          },
          keyValue,
          new Uint8Array(recordValue.ciphertext),
        );
        const session = new TextDecoder().decode(plaintext);
        memory.set(wallet, session);
        return session;
      } catch {
        await removePersisted(wallet);
        return null;
      }
    },

    async delete(walletValue) {
      const wallet = normalizeWallet(walletValue);
      if (!wallet) return;
      memory.delete(wallet);
      await removePersisted(wallet);
    },

    async deleteAll() {
      memory.clear();
      if (!deps.backend) return;
      const keys = await deps.backend.keys().catch(() => []);
      await Promise.allSettled(
        keys.filter((key) => key.startsWith(VAULT_PREFIX)).map((key) => deps.backend!.delete(key)),
      );
    },

    async clearLegacy() {
      if (!deps.backend) return;
      const keys = await deps.backend.keys().catch(() => []);
      await Promise.allSettled(
        keys
          .filter((key) => key === LEGACY_SESSION_KEY || key.startsWith(`${LEGACY_SESSION_KEY}:`))
          .map((key) => deps.backend!.delete(key)),
      );
    },
  };
}

function openDb(): Promise<IDBDatabase> {
  if (typeof indexedDB === "undefined") return Promise.reject(new Error("IndexedDB unavailable"));
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DB_NAME, DB_VERSION);
    request.onupgradeneeded = () => {
      if (!request.result.objectStoreNames.contains(LEGACY_STORE_NAME)) request.result.createObjectStore(LEGACY_STORE_NAME);
      if (!request.result.objectStoreNames.contains(VAULT_STORE_NAME)) request.result.createObjectStore(VAULT_STORE_NAME);
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

function storeForKey(key: string) {
  return key.startsWith(VAULT_PREFIX) ? VAULT_STORE_NAME : LEGACY_STORE_NAME;
}

async function useStore<T>(storeName: string, mode: IDBTransactionMode, action: (store: IDBObjectStore) => IDBRequest<T>) {
  const db = await openDb();
  return new Promise<T>((resolve, reject) => {
    const transaction = db.transaction(storeName, mode);
    const request = action(transaction.objectStore(storeName));
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
    transaction.oncomplete = () => db.close();
    transaction.onerror = () => { db.close(); reject(transaction.error); };
  });
}

function createIndexedDbBackend(): TelegramSessionVaultBackend | null {
  if (typeof indexedDB === "undefined") return null;
  return {
    get: (key) => useStore(storeForKey(key), "readonly", (store) => store.get(key)),
    put: (key, value) => useStore(storeForKey(key), "readwrite", (store) => store.put(value, key)).then(() => undefined),
    delete: (key) => useStore(storeForKey(key), "readwrite", (store) => store.delete(key)).then(() => undefined),
    async keys() {
      const [legacy, vault] = await Promise.all([
        useStore(LEGACY_STORE_NAME, "readonly", (store) => store.getAllKeys()),
        useStore(VAULT_STORE_NAME, "readonly", (store) => store.getAllKeys()),
      ]);
      return [...legacy, ...vault].map(String);
    },
  };
}

const defaultVault = createTelegramSessionVault({
  backend: createIndexedDbBackend(),
  crypto: typeof globalThis.crypto === "undefined" ? null : globalThis.crypto,
});

export async function saveTelegramSession(session: string, wallet: string | null | undefined) {
  return defaultVault.save(wallet, session);
}

export async function readTelegramSession(wallet: string | null | undefined) {
  return defaultVault.read(wallet);
}

export async function deleteTelegramSession(wallet: string | null | undefined) {
  await defaultVault.delete(wallet);
}

export async function deleteAllTelegramSessions() {
  await defaultVault.deleteAll();
  if (typeof localStorage !== "undefined") {
    for (let index = localStorage.length - 1; index >= 0; index -= 1) {
      const key = localStorage.key(index);
      if (key?.startsWith("bem-telegram-")) localStorage.removeItem(key);
    }
  }
}

export async function purgeTelegramLocalIdentity(wallet: string | null | undefined) {
  const normalized = normalizeWallet(wallet);
  if (!normalized) return;
  await defaultVault.delete(normalized);
  if (typeof localStorage !== "undefined") {
    localStorage.removeItem(`bem-telegram-notifications-enabled:${normalized}`);
    localStorage.removeItem(`bem-telegram-unread:${normalized}`);
  }
}

/** 删除旧版明文 Session；新版本绝不自动迁移。 */
export async function 清理旧版全局会话() {
  await defaultVault.clearLegacy();
}
