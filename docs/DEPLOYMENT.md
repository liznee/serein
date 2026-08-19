# Serein 自托管部署指南

> 适用于 Serein V1.0 开源候选版（`open-source-full`）。
>
> 仓库中已经实现的功能全部开放；“稳定核心”和“实验功能”只表示成熟度不同，不是付费等级。

## 1. 部署前先了解边界

Serein 由四部分组成：

```text
HarmonyOS App
      | HTTPS / WSS
Go Backend + SQLite ---- ntfy / optional Push Kit
      | WSS
PC Relay (Node.js + Python)
      | PTY / JSONL
Claude Code CLI / Codex CLI
```

稳定核心包括项目配对、Claude Code/Codex CLI 终端、Claude Code 风险审批、后台通知和基础监控。远程桌面、GitHub/Gitee 社区工作流和 Codex Desktop 接入同样开放源码，但当前仍是实验功能。实验功能不应直接用于无人值守生产主机。

## 2. 环境要求

### 服务器

- Linux 主机；
- Docker Engine 与 Docker Compose v2；
- 一个可配置 HTTPS/WSS 的域名；
- 反向代理可使用 Nginx、Caddy 或 Cloudflare Tunnel。

### PC

- Node.js 18 或更高版本；
- Python 3.10 或更高版本；
- 已安装并可从终端运行的 `claude` 或 `codex`；
- Windows、macOS、Linux 均可运行 CLI；远程桌面 Host 当前仅面向 Windows。

### 手机

- HarmonyOS 设备；
- 从源码构建时需要 DevEco Studio 和与项目匹配的 HarmonyOS SDK；
- 需要使用自己的签名身份，公开仓库不包含任何私人签名文件或密码。

## 3. 启动后端

### 3.1 生成配置

在仓库根目录执行：

```bash
cd deploy
cp backend.env.example .env
../scripts/gen-tokens.sh
```

脚本会输出随机值。将它们分别写入 `deploy/.env`：

```dotenv
HOOK_TOKEN=替换为随机生成的HookToken
PAIR_CODE=替换为随机生成的配对码
NTFY_TOPIC=替换为不可预测的随机Topic
APPROVAL_TIMEOUT=300
PUBLIC_URL=https://your-serein.example.com
```

要求：

- `HOOK_TOKEN`、`PAIR_CODE`、`NTFY_TOPIC` 不能使用示例值或短口令；
- `deploy/.env` 不得提交到 Git；
- `HOOK_TOKEN` 必须与 PC 上 Claude Code Hook/Relay 使用的值一致；
- `PAIR_CODE` 必须与 PC Relay 生成配对二维码时使用的值一致。

### 3.2 启动容器

```bash
docker compose up -d --build
docker compose ps
curl http://127.0.0.1:8080/healthz
```

默认 Compose 只把端口绑定到服务器回环地址：

- 后端：`127.0.0.1:8080`；
- ntfy：`127.0.0.1:8090`。

这是有意的安全默认值。不要为了“方便”直接把这两个端口暴露到公网，应由 HTTPS 反向代理或 Tunnel 对外提供服务。

### 3.3 配置 HTTPS/WSS

`deploy/serein-nginx.conf` 提供了两个通用虚拟主机示例：

- `YOUR_BACKEND_DOMAIN` 转发到 `127.0.0.1:8080`；
- `YOUR_NTFY_DOMAIN` 转发到 `127.0.0.1:8090`。

替换域名和证书路径后验证配置：

```bash
sudo nginx -t
sudo systemctl reload nginx
curl https://your-serein.example.com/healthz
```

WebSocket 需要保留 `Upgrade` 和 `Connection` 请求头。公网部署必须使用 HTTPS/WSS；不要在公网发送明文 Token。

如果服务器不适合开放入站端口，也可以使用 Cloudflare Tunnel。Tunnel 的通用路由应类似：

```yaml
ingress:
  - hostname: your-serein.example.com
    service: http://127.0.0.1:8080
  - hostname: your-ntfy.example.com
    service: http://127.0.0.1:8090
  - service: http_status:404
```

不要把服务器 IP、Tunnel ID、证书、账号目录或真实域名写回公开仓库。

## 4. 安装 PC CLI 与 Hook

### 4.1 从源码安装

```bash
cd /path/to/serein
npm ci
npm install -g .
```

源码目录是开发工作区，全局安装目录是 npm 为 `serein` 命令准备的运行副本。源码修改后，如需让全局命令使用新代码，再执行一次 `npm install -g .`。

### 4.2 配置当前终端

Linux/macOS：

```bash
export SEREIN_BACKEND=https://your-serein.example.com
export SEREIN_HOOK_TOKEN=与服务器HOOK_TOKEN完全一致
export SEREIN_PAIR_CODE=与服务器PAIR_CODE完全一致
```

PowerShell：

```powershell
$env:SEREIN_BACKEND = 'https://your-serein.example.com'
$env:SEREIN_HOOK_TOKEN = '与服务器HOOK_TOKEN完全一致'
$env:SEREIN_PAIR_CODE = '与服务器PAIR_CODE完全一致'
```

代理用户可按需设置 `SEREIN_AGENT_PROXY`，例如 `http://127.0.0.1:7897`。不要把个人代理地址写入公开配置。

### 4.3 初始化并诊断

```bash
serein init
serein doctor
```

`serein init` 会在用户明确执行后合并 Claude Code `PreToolUse` Hook，并保留已有的 Serein 后端地址和 Token。它不会读取服务器上的 `.env`，因此初始化前必须确保当前终端中的值正确。

检查重点：

- `serein doctor` 能访问 `/healthz`；
- `~/.claude/settings.json` 中的 Serein Hook 路径存在；
- Hook 的 `SEREIN_BACKEND` 与服务器公网地址一致；
- Hook Token 与服务器完全一致；
- 不应出现重复的 Serein `PreToolUse` Hook。

### 4.4 启动后台 Relay

```bash
serein daemon
```

Windows 上 `serein init` 会尝试创建隐藏启动项。若不希望开机启动，可移除对应启动项并手动运行 `serein daemon`。

## 5. 注册项目和配对手机

进入需要控制的项目目录：

```bash
cd /path/to/project
serein pair
```

用 App 扫描二维码。Serein 当前采用单主设备绑定：已有主设备未解绑时，另一台手机不能直接替换它。

配对完成后可以：

```bash
serein
serein --agent claude
serein --agent codex
```

如果只选择项目而尚未选择 CLI/Desktop 启动方式，终端页会要求用户先完成启动方式选择。

## 6. 构建 HarmonyOS App

在 Windows 和 DevEco Studio 环境中：

```powershell
cd C:\path\to\serein\harmony
powershell -ExecutionPolicy Bypass -File build2.ps1
```

构建产物通常位于：

```text
harmony/entry/build/default/outputs/default/entry-default-signed.hap
```

公开源码不包含作者的签名配置。请在 DevEco Studio 中创建自己的签名身份后构建。

> 不要运行 `scripts/sign-and-install.ps1`。DevEco 已签名的 HAP 再被其他脚本覆盖后，设备可能报 `fail to verify pkcs7 file`。

## 7. 可选功能

### 7.1 GitHub/Gitee 社区工作流（实验）

如需账号授权，在对应平台创建 OAuth App，并在 `deploy/.env` 填写：

```dotenv
PUBLIC_URL=https://your-serein.example.com
GITHUB_CLIENT_ID=
GITHUB_CLIENT_SECRET=
GITEE_CLIENT_ID=
GITEE_CLIENT_SECRET=
```

回调地址格式：

```text
https://your-serein.example.com/collaboration/oauth/github/callback
https://your-serein.example.com/collaboration/oauth/gitee/callback
```

不使用某个平台时保持对应字段为空，App 会明确显示“后端未配置”，不会伪造账号或仓库数据。Token 不应出现在页面、终端日志或仓库中。

### 7.2 HarmonyOS Push Kit（可选）

App 在线或后台进程仍存活时，WebSocket/ntfy 可负责同步。App 被系统彻底回收后，要获得更可靠的系统通知，需要在 AppGallery Connect 为自己的包名开通 Push Kit，并填写：

```dotenv
HUAWEI_PUSH_CLIENT_ID=
HUAWEI_PUSH_CLIENT_SECRET=
```

详细步骤见 [PUSH_KIT_SETUP.md](PUSH_KIT_SETUP.md)。Client Secret 只能保存在服务器环境变量中。

### 7.3 远程桌面（实验）

远程桌面包含 Windows Host、WebRTC 和输入控制。当前仍需特别注意：

- 仅允许已绑定主设备发起控制；
- 公网跨 NAT 可能需要自行部署 TURN；
- 无人值守、公网和生产主机使用前，应完成独立安全复核；
- 远控失败不应放宽审批、设备绑定或凭证校验。

### 7.4 Codex Desktop（实验）

Codex Desktop 会话发现与接管依赖本机 Codex App/App Server 的实际可用状态。CLI 会话和 Desktop 会话是两种运行方式，App 会要求用户明确选择，不应把普通 CLI 项目伪装成 Desktop 会话。

## 8. 更新、备份与回滚

更新前至少备份后端数据卷中的 SQLite 数据：

```bash
docker compose stop backend
docker run --rm -v deploy_backend-data:/data -v "$PWD":/backup alpine \
  cp /data/serein.db /backup/serein.db.backup
docker compose start backend
```

实际数据卷名称可能带 Compose 项目前缀，请先执行 `docker volume ls` 核对。不要在数据库仍有写入时直接复制 WAL 状态不一致的文件。

更新：

```bash
git pull --ff-only
cd deploy
docker compose up -d --build
curl http://127.0.0.1:8080/healthz
```

回滚时切回已验证的 Git 标签或提交，重新构建容器并恢复与该版本兼容的数据库备份。不要使用 `git reset --hard` 覆盖未保存的本地配置。

## 9. 故障排查

### 后端不健康

```bash
docker compose ps
docker compose logs --tail=200 backend
curl http://127.0.0.1:8080/healthz
```

### PC Relay 离线

```bash
serein doctor
serein daemon
```

确认后端地址是 `https://`，Relay 使用的 Token 与服务器一致，系统代理没有拦截 WebSocket。

### Hook 报 backend unavailable

```bash
curl https://your-serein.example.com/healthz
```

然后检查 `~/.claude/settings.json` 中 Hook 使用的环境变量。后端不可用时 Serein 默认拒绝高风险操作，这是预期的安全行为。

### 官网视频打不开

不要直接用 `file://` 检查视频。仓库根目录执行：

```bash
npm run preview:web
```

保持该终端窗口运行，再访问：

```text
http://127.0.0.1:4173/index.html
```

该预览服务支持 MP4 Range 请求。若网页能打开但视频不能播放，先确认预览进程仍在运行，再检查 `ui/assets/serein-workflow.mp4` 是否存在以及浏览器网络面板是否返回 `206 Partial Content`。

## 10. 发布前安全清单

- [ ] `.env`、Token、OAuth Secret、签名密码没有进入 Git；
- [ ] 公网只开放 HTTPS/WSS，不直接暴露 8080/8090；
- [ ] `HOOK_TOKEN`、`PAIR_CODE`、`NTFY_TOPIC` 使用随机值；
- [ ] `serein doctor` 通过；
- [ ] 高风险操作在后端不可用和审批超时时默认拒绝；
- [ ] 只绑定预期中的主设备；
- [ ] 实验功能仍保留实验标识和权限确认；
- [ ] SQLite 已备份并验证可恢复；
- [ ] 公开导出中没有私人路径、服务器地址、日志、截图或构建缓存。

