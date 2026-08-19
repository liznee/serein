# HarmonyOS Push Kit 配置与验证

Serein 使用两条互补的通知链路：

- App 在线或仍在后台存活时，WebSocket/ntfy 负责快速同步审批；
- App 被系统回收或未运行时，HarmonyOS Push Kit 负责系统通知。

Push Kit 不替代审批鉴权。通知只包含审批 ID、项目名和风险级别，不包含命令正文、
工作目录、Diff、设备 Token、账号凭证或其他敏感内容。用户打开 App 后仍需通过
Serein 后端读取审批并完成鉴权。

## 1. AppGallery Connect 准备

1. 使用已实名认证的华为开发者账号登录 AppGallery Connect。
2. 创建 HarmonyOS 项目和应用，Bundle Name 必须与发布包一致：`com.serein.client`。
3. 使用最终发布签名证书配置应用身份/证书指纹。测试包和正式包必须使用已登记的
   对应签名，不能临时换证书后继续沿用旧指纹。
4. 设置数据处理位置并开通 Push Kit。若控制台要求申请通知场景权益，按实际审批通知
   场景申请，不要把调试消息伪装成营销消息。
5. 从应用凭据页取得 Client ID 和 Client Secret。Secret 只能进入服务器环境变量。

华为官方接入要求包括创建应用、配置签名证书指纹和启用 Push Kit：
<https://developer.huawei.com/consumer/en/codelab/HMSPushKit/index.html>

## 2. 后端配置

在 `deploy/.env` 中填写，不要修改源码常量：

```dotenv
HUAWEI_PUSH_CLIENT_ID=你的_Client_ID
HUAWEI_PUSH_CLIENT_SECRET=你的_Client_Secret
```

`docker-compose.yml` 会映射为：

```text
SEREIN_HUAWEI_PUSH_CLIENT_ID
SEREIN_HUAWEI_PUSH_CLIENT_SECRET
```

直接运行后端时也使用上面两个 `SEREIN_` 前缀的环境变量。OAuth 地址和 Push API
地址已有华为官方默认值；仅测试替身环境才覆盖：

```text
SEREIN_HUAWEI_PUSH_OAUTH_URL
SEREIN_HUAWEI_PUSH_API_BASE
```

严禁把 Client Secret 放进 HarmonyOS App、README 示例值、构建产物日志或 Git 历史。

## 3. 构建与真机验证

DevEco Studio 使用与 AGC 中登记一致的签名构建 HAP，然后直接安装自动签名产物：

```powershell
cd C:/workspace/serein\harmony
powershell -ExecutionPolicy Bypass -File .\build2.ps1

& "C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe" `
  install "C:/workspace/serein\harmony\entry\build\default\outputs\default\entry-default-signed.hap"
```

不要运行 `scripts/sign-and-install.ps1`，它会替换 DevEco 签名并导致身份不一致。

启动 App 后，日志应出现：

```text
serein push kit registration: active=true
```

日志只记录布尔状态和错误码，不打印 Push Token。常见门禁错误：

- `1000900010`：应用身份非法；检查 AGC 应用、Bundle Name、签名证书指纹和安装包签名；
- `1000900012`：相关服务权益未开通或未生效；检查 Push Kit 开通状态。

## 4. 端到端验收

1. App 前台触发一条红色审批，确认只出现一条审批记录；
2. 切到其他 App，再触发一次，确认系统通知可见且无重复；
3. 从最近任务划掉 Serein，等待进程消失后再次触发，确认仍收到系统通知；
4. 点通知进入 Serein，确认加载的是同一个真实审批，而不是通知内容直接执行决定；
5. 连续执行 100 次，记录送达数、重复数、失败码、系统版本和测试时间；
6. 撤销设备后确认旧 Push Token 不再作为发送目标。

第 3 项未通过前，只能标记为 RC，不能宣称后台通知已经达到正式稳定版门禁。
