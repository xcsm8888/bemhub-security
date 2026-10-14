# BEM Hub 链上交易市场

## 合约

- `BemHubCircuitMarket.sol`：ERC-721 固定价、非托管挂卖，成交时资产从 maker 直接转给 taker。
- `BemHubMaterialMarket.sol`：ERC-1155 双向订单与部分成交；卖单资产留在 maker，买单 BNB 由合约托管并可撤单退款。
- `BemHubFeeTreasury.sol`：只接收授权市场手续费，按预设比例分配，不提供任意地址提款。
- `BemHubBase.sol`：两步所有权转移、重入保护与最小接口。

## 生产部署证明

2026-10-14 使用只读链上查询重新取得三个地址的运行时代码，并使用本仓库固定的 Solidity 0.8.28 配置重新编译。三个地址在替换构造期 immutable 后均与编译结果逐字节一致。

| 合约 | BNB Smart Chain 地址 | 运行时代码字节 |
|---|---|---:|
| Fee Treasury | `0x69E8ff50878f4b3eA29299eA543d5311C6A59F6c` | 4,101 |
| Circuit Market | `0x2D2f8D87f6Db449A61Eef8Dd61daF9Cc3a165C35` | 8,473 |
| Material Market | `0xC7F939955AF2340AdC34Ff1Cf33865Dd60dB8C2c` | 9,360 |

部署块、交易哈希和 SHA-256 见 `deployments/bsc-56.json`。

离线编译复核：

```bash
npm run compile:market
```

可选的当前链上复核：

```bash
DEPLOYMENT_RPC_URL="<your-endpoint>" npm run verify:deployment
```

端点只从当前进程环境读取，不写入文件、不进入日志。

## 测试

`test/` 包含正常流程、边界、模糊测试和对抗性不变量测试。测试依赖固定为 `forge-std v1.9.4`，不把第三方依赖复制进本仓库：

```bash
cd market
forge install foundry-rs/forge-std@v1.9.4 --no-git
forge test -vv
```

## 管理权限与限制

- owner 可以在合约上限内修改 taker 费率、管理资产白名单，并分别暂停新订单和成交。
- 暂停不会阻止撤单和退款。
- Fee Treasury owner 可以管理授权市场、三个分配地址和分配比例；比例之和必须为 100%。
- 公开源码和字节码匹配只能证明部署代码与这里一致，不能证明管理密钥治理、运营流程或未来操作一定安全。
