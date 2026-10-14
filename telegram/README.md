# Telegram Session 隐私存储

## 公开内容

- `source/storage.ts`：浏览器端 Session vault 的生产实现。
- `tests/storage.test.ts`：明文不落盘、钱包绑定、篡改/错配删除、内存降级测试。

本模块不包含 Telegram API 凭据、目标群配置、真实 Session、消息内容、用户钱包数据或生产接口配置。

## 工作方式

1. 钱包地址先被规范化并作为记录命名空间。
2. 每次保存生成不可导出的 AES-GCM 256 位 `CryptoKey` 和新的 12 字节 IV。
3. 钱包地址作为 AES-GCM additional authenticated data，复制到另一钱包命名空间的密文无法解密。
4. `CryptoKey` 与密文分别存入 IndexedDB；序列化后的存储内容不含 Session 明文。
5. Web Crypto 或 IndexedDB 不可用时只保存在当前内存，不退回明文持久化。
6. 旧版明文键只删除，不自动迁移。

## 安全边界

这能降低浏览器静态存储被直接读取时的风险，但不是硬件级密钥保护。同源页面脚本在用户已解锁会话时仍可能调用应用逻辑；XSS、恶意浏览器扩展、调试器或已失陷操作系统不在本模块的防护范围内。

运行测试：

```bash
npm test
```
