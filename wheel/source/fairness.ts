import { createHash, createHmac } from "node:crypto";
import { Jackpot玩法表, Lucky玩法表, 游戏配置, 轨道格列表, 轨道格列表V3 } from "./config";
import {
  币种列表,
  type Jackpot特殊玩法,
  type Lucky特殊玩法,
  type 下注分配,
  type 开奖结果,
  type 普通格开奖结果,
  type 普通轨道格,
  type 轨道格,
} from "./types";

function sha256(内容: string | Buffer): string {
  return createHash("sha256").update(内容).digest("hex");
}

export function 承诺种子(种子: Buffer): string {
  return sha256(种子);
}

export function 计算下注摘要(分配: 下注分配): string {
  const 规范 = 币种列表.map((币种) => `${币种}:${分配[币种] ?? 0n}`).join("|");
  return sha256(规范);
}

export function 计算聚合摘要(下注: Array<{ 下注ID: string; 客户端种子: string; 下注摘要: string }>): string {
  const 规范 = [...下注]
    .sort((甲, 乙) => 甲.下注ID.localeCompare(乙.下注ID))
    .map((项) => `${项.下注ID}|${项.客户端种子}|${项.下注摘要}`)
    .join("\n");
  return sha256(规范);
}

export function 计算轮次权重值(输入: {
  服务端种子: Buffer;
  轮次ID: string;
  聚合摘要: string;
  赔率版本: string;
}): bigint {
  const 范围 = 游戏配置.权重总量;
  const 最大值加一 = 1n << 64n;
  const 可接受上限 = 最大值加一 - (最大值加一 % 范围);
  for (let 计数 = 0; 计数 < 1_000; 计数 += 1) {
    const 消息 = [输入.轮次ID, 输入.聚合摘要, 输入.赔率版本, String(计数)].join("\n");
    const 摘要 = createHmac("sha256", 输入.服务端种子).update(消息).digest();
    const 值 = 摘要.subarray(0, 8).readBigUInt64BE();
    if (值 < 可接受上限) return 值 % 范围;
  }
  throw new Error("无法生成无偏随机数");
}

export function 获取轨道格列表(赔率版本: string = 游戏配置.版本): readonly 轨道格[] {
  if (赔率版本 === 游戏配置.版本) return 轨道格列表;
  if (赔率版本 === "crypto-wheel-v3") return 轨道格列表V3;
  throw new Error(`不支持的赔率版本：${赔率版本}`);
}

export function 按权重映射格(随机权重: bigint, 赔率版本: string = 游戏配置.版本): 轨道格 {
  if (随机权重 < 0n || 随机权重 >= 游戏配置.权重总量) throw new Error("随机权重越界");
  let 上限 = 0n;
  for (const 项 of 获取轨道格列表(赔率版本)) {
    上限 += 项.权重;
    if (随机权重 < 上限) return 项;
  }
  throw new Error("结果表权重不完整");
}

export function 按权重映射Jackpot玩法(随机权重: bigint): Jackpot特殊玩法 {
  if (随机权重 < 0n || 随机权重 >= 1_000n) throw new Error("Jackpot随机权重越界");
  let 上限 = 0n;
  for (const 项 of Jackpot玩法表) {
    上限 += 项.权重;
    if (随机权重 < 上限) return 项.玩法;
  }
  throw new Error("Jackpot玩法权重不完整");
}

export function 按权重映射Lucky玩法(随机权重: bigint): Lucky特殊玩法 {
  if (随机权重 < 0n || 随机权重 >= 1_000n) throw new Error("Lucky随机权重越界");
  let 上限 = 0n;
  for (const 项 of Lucky玩法表) {
    上限 += 项.权重;
    if (随机权重 < 上限) return 项.玩法;
  }
  throw new Error("Lucky玩法权重不完整");
}

type 随机输入 = {
  服务端种子: Buffer;
  轮次ID: string;
  聚合摘要: string;
  赔率版本: string;
};

function 计算派生随机值(输入: 随机输入, 领域: string, 范围: bigint): bigint {
  const 最大值加一 = 1n << 64n;
  const 可接受上限 = 最大值加一 - (最大值加一 % 范围);
  for (let 计数 = 0; 计数 < 1_000; 计数 += 1) {
    const 消息 = [输入.轮次ID, 输入.聚合摘要, 输入.赔率版本, 领域, String(计数)].join("\n");
    const 摘要 = createHmac("sha256", 输入.服务端种子).update(消息).digest();
    const 值 = 摘要.subarray(0, 8).readBigUInt64BE();
    if (值 < 可接受上限) return 值 % 范围;
  }
  throw new Error("无法生成派生无偏随机数");
}

function 普通结果(格: 普通轨道格): 普通格开奖结果 {
  const { 权重: _权重, ...结果 } = 格;
  return 结果;
}

function 查找普通结果(币种: 普通轨道格["币种"], 奖级: 普通轨道格["奖级"], 赔率版本: string): 普通格开奖结果 {
  const 格 = 获取轨道格列表(赔率版本).find((项) => 项.类型 === "symbol" && 项.币种 === 币种 && 项.奖级 === 奖级);
  if (!格 || 格.类型 !== "symbol") throw new Error("特殊玩法格配置缺失");
  return 普通结果(格);
}

function 顺时针火车(起始格: number, 赔率版本: string): 普通格开奖结果[] {
  const 命中格: 普通格开奖结果[] = [];
  let 格号 = 起始格;
  const 轨道格 = 获取轨道格列表(赔率版本);
  while (命中格.length < 游戏配置.Lucky送灯数量) {
    const 格 = 轨道格[格号 % 轨道格.length];
    if (格.类型 === "symbol") 命中格.push(普通结果(格));
    格号 += 1;
  }
  return 命中格;
}

function Jackpot命中格(玩法: Jackpot特殊玩法, 赔率版本: string): 普通格开奖结果[] {
  if (玩法 === "big-three") return [["BNB", "big"], ["SOL", "big"], ["XRP", "big"]].map(([币种, 奖级]) => 查找普通结果(币种 as 普通轨道格["币种"], 奖级 as 普通轨道格["奖级"], 赔率版本));
  if (玩法 === "small-three") return [["HYPE", "big"], ["BEM", "big"], ["DOGE", "big"]].map(([币种, 奖级]) => 查找普通结果(币种 as 普通轨道格["币种"], 奖级 as 普通轨道格["奖级"], 赔率版本));
  if (玩法 === "big-grand") return 币种列表.filter((币种) => 币种 !== "BTC").map((币种) => 查找普通结果(币种, "big", 赔率版本));
  if (玩法 === "small-grand") return 币种列表.filter((币种) => 币种 !== "BTC").map((币种) => 查找普通结果(币种, "small", 赔率版本));
  if (玩法 === "harvest") return ["BNB", "HYPE", "BEM", "DOGE"].map((币种) => 查找普通结果(币种 as 普通轨道格["币种"], "big", 赔率版本));
  return [];
}

export function 生成开奖结果(输入: 随机输入): 开奖结果 {
  const 主格 = 按权重映射格(计算轮次权重值(输入), 输入.赔率版本);
  if (主格.类型 === "symbol") return 普通结果(主格);
  if (主格.类型 === "lucky") {
    const 特殊玩法 = 按权重映射Lucky玩法(计算派生随机值(输入, "lucky:program", 1_000n));
    const 起始格 = Number(计算派生随机值(输入, "lucky:train:start", BigInt(获取轨道格列表(输入.赔率版本).length)));
    const 命中格 = 特殊玩法 === "train" ? 顺时针火车(起始格, 输入.赔率版本) : [];
    return { 类型: "lucky", 格号: 主格.格号, 代码: "LUCKY", 特殊玩法, 命中格 };
  }
  const 特殊玩法 = 按权重映射Jackpot玩法(计算派生随机值(输入, "jackpot:program", 1_000n));
  return { 类型: "jackpot", 格号: 主格.格号, 代码: "JACKPOT", 特殊玩法, 命中格: Jackpot命中格(特殊玩法, 输入.赔率版本) };
}

function 是普通结果(value: unknown, 赔率版本: string): value is 普通格开奖结果 {
  if (!value || typeof value !== "object") return false;
  const result = value as Partial<普通格开奖结果>;
  const 格 = 获取轨道格列表(赔率版本).find((项) => 项.格号 === result.格号);
  return 格?.类型 === "symbol" && result.类型 === "symbol" && result.代码 === 格.代码
    && result.币种 === 格.币种 && result.奖级 === 格.奖级 && result.倍数 === 格.倍数;
}

function 是开奖结果(value: unknown, 赔率版本: string): value is 开奖结果 {
  if (是普通结果(value, 赔率版本)) return true;
  if (!value || typeof value !== "object") return false;
  const result = value as Partial<Extract<开奖结果, { 类型: "lucky" | "jackpot" }>> & { 命中格?: unknown[] };
  if (result.类型 === "lucky") {
    const 玩法有效 = Lucky玩法表.some((项) => 项.玩法 === result.特殊玩法);
    const 数量有效 = result.特殊玩法 === "train" ? result.命中格?.length === 游戏配置.Lucky送灯数量 : result.命中格?.length === 0;
    return result.格号 === 9 && result.代码 === "LUCKY" && 玩法有效 && Array.isArray(result.命中格)
      && 数量有效 && result.命中格.every((格) => 是普通结果(格, 赔率版本));
  }
  if (result.类型 !== "jackpot" || result.格号 !== 21 || result.代码 !== "JACKPOT") return false;
  if (!Jackpot玩法表.some((项) => 项.玩法 === result.特殊玩法)) return false;
  if (!Array.isArray(result.命中格) || !result.命中格.every((格) => 是普通结果(格, 赔率版本))) return false;
  return JSON.stringify(result.命中格) === JSON.stringify(Jackpot命中格(result.特殊玩法 as Jackpot特殊玩法, 赔率版本));
}

export function 序列化开奖结果(结果: 开奖结果, 赔率版本: string = 游戏配置.版本): string {
  if (!是开奖结果(结果, 赔率版本)) throw new Error("开奖结果格式无效");
  return JSON.stringify(结果);
}

export function 解析开奖结果(原始: string, 赔率版本: string = 游戏配置.版本): 开奖结果 {
  let value: unknown;
  try { value = JSON.parse(原始); } catch { throw new Error("开奖结果格式无效"); }
  if (!是开奖结果(value, 赔率版本)) throw new Error("开奖结果格式无效");
  return value;
}
