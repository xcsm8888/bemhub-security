import type { Jackpot特殊玩法, Lucky特殊玩法, 轨道格 } from "./types";

export const 积分单位 = 100n;
/** 激活只创建账户，不自动发放积分。保留导出供旧调用方平滑迁移。 */
export const 初始积分单位数 = 0n;
/** 每次主动领取 10,000 积分。 */
export const 每日积分单位数 = 1_000_000n;
export const 基础奖池单位数 = 1_000_000n;

/** 顺时针排列的 24 格跑马灯；重复格共享同一奖级的总概率。 */
/** 已结算的 crypto-wheel-v3 轮次使用的不可变历史轨道，禁止按 v4 规则重算。 */
export const 轨道格列表V3: readonly 轨道格[] = Object.freeze([
  { 格号: 0, 代码: "BEM_BIG_A", 类型: "symbol", 币种: "BEM", 奖级: "big", 倍数: 10, 权重: 17_088n },
  { 格号: 1, 代码: "XRP_BIG_A", 类型: "symbol", 币种: "XRP", 奖级: "big", 倍数: 20, 权重: 17_570n },
  { 格号: 2, 代码: "BTC_SMALL", 类型: "symbol", 币种: "BTC", 奖级: "small", 倍数: 50, 权重: 12_378n },
  { 格号: 3, 代码: "BTC_BIG_A", 类型: "symbol", 币种: "BTC", 奖级: "big", 倍数: 120, 权重: 1_311n },
  { 格号: 4, 代码: "DOGE_BIG_A", 类型: "symbol", 币种: "DOGE", 奖级: "big", 倍数: 5, 权重: 35_709n },
  { 格号: 5, 代码: "DOGE_SMALL", 类型: "symbol", 币种: "DOGE", 奖级: "small", 倍数: 3, 权重: 131_873n },
  { 格号: 6, 代码: "HYPE_BIG_A", 类型: "symbol", 币种: "HYPE", 奖级: "big", 倍数: 15, 权重: 19_884n },
  { 格号: 7, 代码: "BNB_BIG", 类型: "symbol", 币种: "BNB", 奖级: "big", 倍数: 20, 权重: 35_012n },
  { 格号: 8, 代码: "BNB_SMALL", 类型: "symbol", 币种: "BNB", 奖级: "small", 倍数: 3, 权重: 74_988n },
  { 格号: 9, 代码: "LUCKY", 类型: "lucky", 权重: 5_000n },
  { 格号: 10, 代码: "BEM_BIG_B", 类型: "symbol", 币种: "BEM", 奖级: "big", 倍数: 10, 权重: 17_089n },
  { 格号: 11, 代码: "BEM_SMALL", 类型: "symbol", 币种: "BEM", 奖级: "small", 倍数: 3, 权重: 195_823n },
  { 格号: 12, 代码: "BTC_BIG_B", 类型: "symbol", 币种: "BTC", 奖级: "big", 倍数: 120, 权重: 1_311n },
  { 格号: 13, 代码: "XRP_BIG_B", 类型: "symbol", 币种: "XRP", 奖级: "big", 倍数: 20, 权重: 17_570n },
  { 格号: 14, 代码: "ETH_SMALL", 类型: "symbol", 币种: "ETH", 奖级: "small", 倍数: 3, 权重: 45_132n },
  { 格号: 15, 代码: "ETH_BIG", 类型: "symbol", 币种: "ETH", 奖级: "big", 倍数: 40, 权重: 19_868n },
  { 格号: 16, 代码: "DOGE_BIG_B", 类型: "symbol", 币种: "DOGE", 奖级: "big", 倍数: 5, 权重: 35_709n },
  { 格号: 17, 代码: "HYPE_SMALL", 类型: "symbol", 币种: "HYPE", 奖级: "small", 倍数: 3, 权重: 110_231n },
  { 格号: 18, 代码: "HYPE_BIG_B", 类型: "symbol", 币种: "HYPE", 奖级: "big", 倍数: 15, 权重: 19_885n },
  { 格号: 19, 代码: "SOL_SMALL", 类型: "symbol", 币种: "SOL", 奖级: "small", 倍数: 3, 权重: 49_095n },
  { 格号: 20, 代码: "SOL_BIG", 类型: "symbol", 币种: "SOL", 奖级: "big", 倍数: 30, 权重: 25_905n },
  { 格号: 21, 代码: "JACKPOT", 类型: "jackpot", 权重: 1_000n },
  { 格号: 22, 代码: "DOGE_BIG_C", 类型: "symbol", 币种: "DOGE", 奖级: "big", 倍数: 5, 权重: 35_709n },
  { 格号: 23, 代码: "XRP_SMALL", 类型: "symbol", 币种: "XRP", 奖级: "small", 倍数: 3, 权重: 74_860n },
]);

/** crypto-wheel-v4：右列去除重复 BTC 大奖格，补入 DOGE 与 BEM 大奖格。 */
export const 轨道格列表: readonly 轨道格[] = Object.freeze(轨道格列表V3.map((格): 轨道格 => {
  if (格.类型 !== "symbol") return { ...格 };
  if (格.格号 === 3) return { ...格, 类型: "symbol", 代码: "BTC_BIG_A", 币种: "BTC", 奖级: "big", 倍数: 120, 权重: 2_622n };
  if (格.格号 === 4 || 格.格号 === 16 || 格.格号 === 22) return { ...格, 类型: "symbol", 权重: 23_806n };
  if (格.格号 === 10) return { 格号: 10, 代码: "DOGE_BIG_D", 类型: "symbol", 币种: "DOGE", 奖级: "big", 倍数: 5, 权重: 35_709n };
  if (格.格号 === 12) return { 格号: 12, 代码: "BEM_BIG_B", 类型: "symbol", 币种: "BEM", 奖级: "big", 倍数: 10, 权重: 17_089n };
  return { ...格 };
}));

export const Lucky玩法表: ReadonlyArray<{ 玩法: Lucky特殊玩法; 权重: bigint }> = Object.freeze([
  { 玩法: "train", 权重: 700n },
  { 玩法: "blank", 权重: 300n },
]);

export const Jackpot玩法表: ReadonlyArray<{ 玩法: Jackpot特殊玩法; 权重: bigint }> = Object.freeze([
  { 玩法: "big-three", 权重: 220n },
  { 玩法: "small-three", 权重: 220n },
  { 玩法: "big-grand", 权重: 80n },
  { 玩法: "small-grand", 权重: 100n },
  { 玩法: "harvest", 权重: 110n },
  { 玩法: "shared-jackpot", 权重: 20n },
  { 玩法: "blank", 权重: 250n },
]);

export const 游戏配置 = Object.freeze({
  版本: "crypto-wheel-v4" as const,
  权重总量: 1_000_000n,
  普通格权重总量: 994_000n,
  Lucky送灯数量: 5,
  目标返还PPM: 960_000n,
  永久回收PPM: 40_000n,
  结果表: 轨道格列表,
});

/** PostgreSQL bigint 的有符号上界；仅用于防止结算和账本写入溢出。 */
export const 最大存储单位数 = 9_223_372_036_854_775_807n;
/** Lucky 最多送灯次数 × 单格最高倍数，作为任何可达结果的保守结算上界。 */
export const 单票最坏奖励倍数 = BigInt(游戏配置.Lucky送灯数量) * BigInt(Math.max(...轨道格列表.filter((格) => 格.类型 === "symbol").map((格) => 格.倍数)));
