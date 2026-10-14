export const 币种列表 = ["BTC", "ETH", "SOL", "BNB", "XRP", "HYPE", "BEM", "DOGE"] as const;

export type 币种代码 = (typeof 币种列表)[number];
export type 奖级 = "big" | "small";
export type 下注分配 = Partial<Record<币种代码, bigint>>;

export type 普通轨道格 = {
  格号: number;
  代码: string;
  类型: "symbol";
  币种: 币种代码;
  奖级: 奖级;
  倍数: number;
  权重: bigint;
};

export type 特殊轨道格 = {
  格号: number;
  代码: "LUCKY" | "JACKPOT";
  类型: "lucky" | "jackpot";
  权重: bigint;
};

export type 轨道格 = 普通轨道格 | 特殊轨道格;
export type 普通格开奖结果 = Omit<普通轨道格, "权重">;
export type Lucky特殊玩法 = "train" | "blank";
export type Jackpot特殊玩法 = "big-three" | "small-three" | "big-grand" | "small-grand" | "harvest" | "shared-jackpot" | "blank";

export type 开奖结果 =
  | 普通格开奖结果
  | { 类型: "lucky"; 格号: number; 代码: "LUCKY"; 特殊玩法: Lucky特殊玩法; 命中格: 普通格开奖结果[] }
  | { 类型: "jackpot"; 格号: number; 代码: "JACKPOT"; 特殊玩法: Jackpot特殊玩法; 命中格: 普通格开奖结果[] };

export type 轮盘结果 = 开奖结果;
export type 结果配置 = 轨道格;

export type 轮次窗口 = {
  轮次ID: string;
  开盘时间: Date;
  封盘时间: Date;
  开奖时间: Date;
};

export type 票据奖励 = {
  总下注: bigint;
  毛奖励: bigint;
  净输赢: bigint;
};
