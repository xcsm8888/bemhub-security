# BEM Hub 安全公开仓库

本仓库公开 BEM Hub 三个可独立核验的安全核心：Telegram Session 本地加密、幸运转盘确定性公平算法、链上交易市场合约。目标是让任何人都能阅读源码并在本地复现关键结论，同时不公开生产配置、用户数据或基础设施信息。

> **本仓库不是第三方审计报告（NOT THIRD-PARTY AUDITED）。** 它提供可复现源码、测试与部署字节码证明，不能代替独立安全公司的完整审计。

## 公开范围

| 模块 | 可核验内容 | 主要边界 |
|---|---|---|
| [Telegram 隐私存储](telegram/README.md) | AES-256-GCM、钱包绑定、明文不落盘、失败时内存降级 | 不能抵御同源恶意脚本或浏览器环境已失陷 |
| [幸运转盘公平性](wheel/README.md) | 种子承诺、HMAC-SHA256、拒绝采样、结果映射、离线验证器 | 不能单凭公开证明确认服务器提交的下注集合绝对完整 |
| [链上交易市场](market/README.md) | 三份 Solidity 合约、测试、编译哈希、BSC 部署字节码一致性 | owner 仍拥有费率上限内调整、白名单和暂停权限 |

明确不公开：任何生产 RPC 地址或密钥、服务器地址与路径、环境变量值、数据库配置、管理入口、Telegram 实际凭据/Session/消息、轮盘生产种子/密钥、充值和资金归集实现、用户隐私数据。

## 一键复现

需要 Node.js 20+：

```bash
npm ci
npm run verify:all
```

该命令执行 7 项行为测试、TypeScript 类型检查、Solidity 0.8.28 离线编译/字节码哈希比对，以及公开目录隐私扫描。

验证公开的轮盘示例：

```bash
npx tsx wheel/verifier.ts wheel/vectors/public-example.json
```

运行 Foundry 合约测试（需预装 Foundry）：

```bash
cd market
forge test -vv
```

链上部署复核是可选操作。调用方自行提供临时节点端点；脚本不会打印或保存该值：

```bash
DEPLOYMENT_RPC_URL="<your-endpoint>" npm run verify:deployment
```

## 可追溯性

- [MANIFEST.json](MANIFEST.json) 固定本次公开范围内每个核心文本文件按 LF 规范化后的 SHA-256，跨平台检出结果一致。
- [market/compiled-bytecode-sha256.json](market/compiled-bytecode-sha256.json) 固定编译器参数和三份合约编译结果。
- [market/deployments/bsc-56.json](market/deployments/bsc-56.json) 记录公开链上地址、部署交易与当前运行时代码哈希。
- 2026-10-14 的只读复核结果：三份链上运行时代码均与本仓库源码编译结果完全一致（含 immutable 地址归一化后比较）。

English summary: see [README.en.md](README.en.md).

## 许可证

本仓库自有代码使用 MIT License；`market/lib/forge-std` 保留其上游许可证与来源记录。
