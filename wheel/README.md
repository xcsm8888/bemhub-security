# 幸运转盘公平性

## 公开内容

- `source/fairness.ts`：种子承诺、下注摘要、聚合摘要、无偏随机值和结果映射。
- `source/config.ts` / `source/types.ts`：公开赔率版本、权重表和结果类型。
- `source/seed-vault.ts`：服务端种子静态加密算法；不含任何生产密钥或种子。
- `verifier.ts`：离线证明验证器。
- `vectors/public-example.json`：完全虚构、可重复的公开测试向量。

## 算法

1. 开盘前对 32 字节服务端种子计算 SHA-256 承诺。
2. 每张票按固定币种顺序生成下注摘要；票据按下注 ID 排序后生成轮次聚合摘要。
3. 使用 `HMAC-SHA256(serverSeed, roundId + aggregateHash + paytableVersion + counter)` 派生随机值。
4. 只接受不会产生模偏差的 64 位值，再映射至 1,000,000 总权重的公开轨道。
5. Lucky/Jackpot 的派生玩法使用独立领域字符串，避免复用同一随机值。
6. 结算后公开种子，验证器复算承诺和开奖结果。

验证示例：

```bash
npx tsx wheel/verifier.ts wheel/vectors/public-example.json
```

有效输出必须同时满足 `commitmentMatches=true`、`resultMatches=true` 和 `valid=true`。

## 重要限制

当前证明可以验证“公开种子确实对应事先给出的承诺”和“给定聚合摘要必然得到该结果”。但验证者若没有每一张已接受票据的独立公开清单，就不能只凭聚合摘要证明服务器没有漏掉某张票。这是当前方案的明确可信边界，不应宣传为完全去信任化。
