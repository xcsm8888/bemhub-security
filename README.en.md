# BEM Hub Security Transparency

This repository publishes three independently reproducible security components: encrypted local storage for Telegram sessions, the deterministic lucky-wheel fairness algorithm, and the on-chain market contracts.

> **NOT THIRD-PARTY AUDITED.** Reproducible source, tests, and bytecode matching improve transparency but do not replace an independent professional audit.

## Scope

- `telegram/`: AES-256-GCM session vault with wallet-bound associated data and memory-only fallback.
- `wheel/`: seed commitment, HMAC-SHA256 randomness, rejection sampling, result mapping, and an offline verifier.
- `market/`: Solidity contracts, Foundry tests, reproducible compiler settings, and BNB Smart Chain deployment evidence.

Production endpoints, credentials, server details, databases, admin routes, real Telegram data, production wheel seeds/keys, deposit monitoring, fund sweeping, and user data are intentionally excluded.

## Verify

```bash
npm ci
npm run verify:all
npx tsx wheel/verifier.ts wheel/vectors/public-example.json
```

For Solidity execution tests, install Foundry and run `forge test -vv` inside `market/`.

The current wheel proof verifies the revealed seed commitment and deterministic result for the supplied aggregate hash. It does **not** independently prove that the aggregate includes every accepted bet. See each module README for the complete trust boundary.
