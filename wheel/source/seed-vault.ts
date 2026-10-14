import { createCipheriv, createDecipheriv, randomBytes as nodeRandomBytes } from "node:crypto";
import { CryptoWheelError } from "./errors";

function 解析密钥(Base64密钥: string): Buffer {
  try {
    const 密钥 = Buffer.from(Base64密钥, "base64");
    if (密钥.length !== 32 || 密钥.toString("base64") !== Base64密钥) throw new Error("invalid");
    return 密钥;
  } catch {
    throw new CryptoWheelError("SEED_CONFIGURATION_INVALID", "GAME_SEED_SECRET 必须是 32 字节 Base64", 503);
  }
}

export function 加密服务端种子(种子: Buffer, Base64密钥: string, 固定IV?: Buffer): string {
  const 密钥 = 解析密钥(Base64密钥);
  const iv = 固定IV ?? nodeRandomBytes(12);
  if (iv.length !== 12) throw new CryptoWheelError("SEED_CONFIGURATION_INVALID", "种子 IV 长度无效", 503);
  const cipher = createCipheriv("aes-256-gcm", 密钥, iv);
  const 密文 = Buffer.concat([cipher.update(种子), cipher.final()]);
  const tag = cipher.getAuthTag();
  return ["v1", iv.toString("base64url"), tag.toString("base64url"), 密文.toString("base64url")].join(".");
}

export function 解密服务端种子(信封: string, Base64密钥: string): Buffer {
  try {
    const 密钥 = 解析密钥(Base64密钥);
    const [版本, iv文本, tag文本, 密文文本, 多余] = 信封.split(".");
    if (版本 !== "v1" || !iv文本 || !tag文本 || !密文文本 || 多余 !== undefined) throw new Error("invalid envelope");
    const iv = Buffer.from(iv文本, "base64url");
    const tag = Buffer.from(tag文本, "base64url");
    const 密文 = Buffer.from(密文文本, "base64url");
    if (iv.length !== 12 || tag.length !== 16 || !密文.length) throw new Error("invalid envelope");
    const decipher = createDecipheriv("aes-256-gcm", 密钥, iv);
    decipher.setAuthTag(tag);
    return Buffer.concat([decipher.update(密文), decipher.final()]);
  } catch (error) {
    if (error instanceof CryptoWheelError && error.code === "SEED_CONFIGURATION_INVALID") throw error;
    throw new CryptoWheelError("SEED_DECRYPT_FAILED", "种子解密失败", 500);
  }
}
