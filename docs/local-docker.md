# Windows 本地容器部署

Docker Desktop 和 WSL 已于 2026-10-07 安装；2026-10-08 重启后，Docker Engine 29.8.2 已正常运行，7 个本地服务镜像构建和容器健康检查均已通过。再次开机后先打开 Docker Desktop，等待引擎就绪。

## 启动

在 RAIOT 根目录执行：

```powershell
.\Start-Local.ps1 -ValidateOnly
.\Start-Local.ps1
```

脚本首次生成 `.env.local` 的随机 MySQL、Redis、MQTT 凭据；`.local/task-tokens.json` 缺失时生成三类令牌，已有文件保持原样。文件被 Git 忽略，Windows ACL 限当前用户和 SYSTEM。脚本不读取旧 `.env.raiot`，不结束占用端口的进程，也不改写 ESP32 固件配置。

脚本会在 Docker 命令执行期间使用 Windows 已启用的显式 HTTP 系统代理，已有 `HTTPS_PROXY` 优先；构建容器的代理地址由 `LOCAL_BUILD_PROXY` 控制，本机回环代理会转换为 `host.docker.internal`。执行结束恢复原环境变量，不改系统代理或 Docker daemon 设置，代理不写入镜像 `ENV`。这解决本机 Docker 拉镜像成功、Buildx 获取 Docker Hub 令牌却超时的问题；CLI 代理变量见 [Docker 官方说明](https://docs.docker.com/reference/cli/docker/#environment-variables)。

默认启动 MySQL、Redis、Java 后端、任务 API 和 Admin。数据库只使用 `raiot-local` 项目专属卷，未向宿主发布数据库或 Redis 端口。Java 通过 `application-local.yml` 使用现有 Liquibase changelog 建表；请勿导入旧数据库覆盖此卷。

| 服务 | 本机地址 | 说明 |
| --- | --- | --- |
| Admin | http://127.0.0.1:8001 | 管理后台与任务列表 |
| Java API | http://127.0.0.1:8002/richard | 首次注册流程沿用原仓实现 |
| 任务 API | http://127.0.0.1:8010 | 手机、Admin、Windows worker 共用任务状态 |

启动时端口若被本机开发服务器占用，先停止对应开发服务器后再执行。不要同时在同一端口启动容器版本与本机版本。任务 API 容器使用独立数据库卷；若之前使用过本机模式，其本机数据库不会自动复制到容器。

本次已单独完成历史迁移：停止任务 API 后，仅向确认空白的 `raiot-local_task-data` 卷导入 SQLite 一致性备份，保留 3 条已取消任务和 6 条事件，完整性检查通过。原数据库及 `.local/runs-before-docker-20261008.db` 备份均保留；不要向已有任务的卷重复覆盖导入。Redmi 普通 App 已通过 USB 连接容器 API，首页显示原任务。

首次访问 [注册页](http://127.0.0.1:8001/#/register) 创建本机管理员，首个用户自动成为超级管理员，需手动填写图片验证码。后台与独立任务监控的登录方式不同：`/local-runs.html` 使用本机 `.local/task-tokens.json` 的 `admin` 角色令牌，不能用于 Java 后台登录。

云端 Hermes 浏览器执行器仍单独运行在 Windows，按 `scripts/Start-AgentWorker.ps1` 说明接入任务 API。Kubeconfig 和模型密钥没有复制进 Docker 镜像。

## 语音 AI 与 MQTT

本机的 `SenseVoiceSmall/model.pt` 已于 2026-10-07 从官方 ModelScope 下载并验证，文件没有加入 Git。2026-10-08 已在本机数据库新增 `LLM_BailianQwenPlus` 并让默认 Agent 模板引用它，沿用已有百炼 `qwen-plus` 与业务空间兼容端点；密钥从受限本地文件读取，没有打进镜像或提交 Git。一次最小模型请求已成功（12 tokens），这不等于硬件语音或 Hermes 全链路通过。

1. 本机权重已准备；在另一台机器上需从官方 [iic/SenseVoiceSmall](https://www.modelscope.cn/models/iic/SenseVoiceSmall) 下载 `model.pt` 到 `Richard-ai-server/models/SenseVoiceSmall/model.pt`。本次固定 revision 为 `70514a3da51f1160f51d18449dab6128bbd4928b`，大小 **936,291,369 bytes**，SHA256 为 `833ca2dcfdf8ec91bd4f31cfac36d6124e0c459074d5e909aec9cabe6204a3ea`，与官方 API 元数据一致。仓库已有两份模型配置在统一换行符后与官方一致，tokenizer 二进制校验一致；未执行下载模型附带代码。
2. 本机默认模板已选择新建的百炼 LLM、`ASR_FunASR`、`TTS_EdgeTTS`、`Memory_nomem`；其他机器需在 Admin 配置可用 LLM、TTS/ASR 参数。新 Agent 继承模板，已有 Agent 需单独选择模型。百炼密钥填配置时不要提交 Git。
3. 执行 `.\Start-Local.ps1 -WithVoice`。首次 Python 镜像构建会下载 CPU PyTorch 与语音依赖，体积和耗时较大。

脚本读取 Java 后端为本地数据库生成的 `server.secret`，生成 `.local/ai-config.yaml`，将 MQTT 签名及设备访问地址写入本地 `sys_params`，仅清理对应配置缓存。AI 读取 Java 配置，MQTT 使用相同密钥连接 AI。

模型目录以 `./Richard-ai-server/models:/app/models:ro` 挂载，AI 配置以 `./.local/ai-config.yaml:/app/data/.config.yaml:ro` 挂载；Dockerfile 将 `models`、`data` 和环境文件排除在镜像构建上下文外。模型资源校验记录在 `.local/sensevoice-resource-verification.json`。本机现已完成 SenseVoiceSmall 实际加载、中文样例识别及 EdgeTTS → ASR 回读验证，详情见下方验收边界；其他机器仍需配置实际模型选择及调用凭据。

AI WebSocket 为 `9000`，HTTP 为 `9003`，MQTT TCP 为 `1883`，音频 UDP 为 `8884`，MQTT 管理 API 为 `8007`。`8884` 是 UDP 音频端口，并非 TLS MQTT 端口。

## 小智硬件局域网连接

默认所有可发布端口固定绑定 `127.0.0.1`。`LOCAL_BIND_IP` 不再改变端口发布范围；不要通过修改 `.env.local` 把整个后台开放到局域网。硬件联调使用额外的 `compose.lan.yml`，只追加指定网卡上的硬件端口，并保留原有回环入口。

先确认 ESP32 与电脑连接同一可互访的 Wi-Fi。当前电脑 WLAN 地址是 `192.168.0.105/24`，可能随 DHCP 改变；每次启用时脚本都会检查地址确实属于已连接的物理网卡，排除 Docker/WSL 虚拟网卡、回环及自动分配的链路地址。只有一个候选地址时可省略 `-LanIPAddress`，有多个时必须明确指定。

```powershell
# 普通 PowerShell：只校验地址和 Compose，不启动容器。
.\Start-Local.ps1 -WithVoice -WithLan -LanIPAddress 192.168.0.105 -ValidateOnly

# 明确准备进行硬件联调后执行；会更新设备访问地址并重建相关容器。
.\Start-Local.ps1 -WithVoice -WithLan -LanIPAddress 192.168.0.105
```

`-WithLan` 必须与 `-WithVoice` 一起使用。LAN 地址仅用于本次 Compose 覆盖和设备广告地址，不修改 `.env.local` 的网络配置；脚本结束恢复进程里的 `LOCAL_LAN_IP`。`server.websocket`、`server.ota`、MQTT/UDP 地址使用指定 LAN IP，`server.fronted_url` 始终保留 `http://127.0.0.1:8001/`，用户在这台电脑完成设备绑定。

| 入口 | 本机回环 | 指定 LAN 地址 |
| --- | --- | --- |
| Java OTA/API TCP 8002 | 保留 | 追加 |
| AI WebSocket TCP 9000、HTTP TCP 9003 | 保留 | 追加 |
| MQTT TCP 1883、音频 UDP 8884 | 保留 | 追加 |
| Admin TCP 8001、任务 API TCP 8010、MQTT 管理 TCP 8007 | 保留 | 不开放 |
| MySQL、Redis | 容器内部 | 不开放 |

Windows 防火墙单独处理，启动脚本不会自动修改它。以下校验无需管理员权限：

```powershell
.\scripts\Set-LocalHardwareFirewall.ps1 -LanIPAddress 192.168.0.105 -ValidateOnly
```

确认范围后，在**以管理员身份运行的 PowerShell** 中执行：

```powershell
.\scripts\Set-LocalHardwareFirewall.ps1 -LanIPAddress 192.168.0.105
# 联调结束后移除这两条 RAIOT 专用规则。
.\scripts\Set-LocalHardwareFirewall.ps1 -LanIPAddress 192.168.0.105 -Remove
```

脚本只允许 TCP `8002,9000,9003,1883` 和 UDP `8884`，同时限定网卡、目标本地 IP 和该网卡前缀算出的来源子网（此处为 `192.168.0.0/24`）。规则适用所有网络类别，因此当前 Public 网络无需改成 Private；脚本不会关闭防火墙、修改网络类别、开放管理端口或设置路由器公网映射。重复执行只更新同名 RAIOT 规则，也支持 `-WhatIf` 预览。

2026-10-08 已应用上述 LAN 配置和两条防火墙规则。硬件相关三个容器健康，指定 LAN TCP 端口可从本机连接，其他四个容器未因 LAN 调整重启；UDP 端口映射已核对。证据为 `.local/lan-deployment-verification.json` 与 `.local/lan-firewall-result.json`。这些检查还不能替代真实 Wi-Fi 设备的连接与语音验收。

切回只在本机访问时执行 `.\Start-Local.ps1 -WithVoice`，然后移除上述防火墙规则；Compose 会去掉追加的 LAN 端口。只读查看包含 LAN 覆盖的配置时，应同时传两个 Compose 文件且只输出 `config --quiet` 或筛选后的端口，完整展开配置含本地凭据，不要复制分享。

## 查看与停止

```powershell
docker compose --env-file .env.local -f compose.local.yml --profile voice ps
docker compose --env-file .env.local -f compose.local.yml logs --tail 100 backend
docker compose --env-file .env.local -f compose.local.yml --profile voice stop
```

停止保留数据库、任务数据与固件上传卷。不要使用 `down -v`，除非明确需要清空本地测试数据。`.env.local` 被删除后不要直接生成新密码搭配旧卷；旧卷仍使用创建时的密码。

## 本次验证边界

- Docker Desktop 4.94.0、Docker CLI 29.8.2、Compose v5.5.1、WSL 3.0.1.0 已安装。
- Java 后端已用本机 JDK 21 / Maven 构建成功。
- SenseVoiceSmall 权重已下载，大小和 SHA256 已核对官方元数据；已加载执行中文样例识别及合成音频回读，随后完成下述 ESP32 实物语音验证。
- Compose 配置、PowerShell 语法及代理环境恢复检查通过；7 个服务容器健康。
- MySQL migrations、后端公共配置及 SM2 初始化通过，未登录模型接口拒绝访问；Admin 注册/登录、反向代理、任务监控和窄屏布局共 14 项验收通过。
- MQTT 健康检查同时检查 1883 和管理 API 8007，机器生成的 256 位十六进制签名密钥可用，日志不打印认证令牌。
- 后端镜像排除了原仓库 `application-dev.yml`，已核对最终 JAR 包含 local 配置且不包含 dev 配置。
- 语音功能验收通过：无网络临时容器加载 SenseVoiceSmall 并识别官方中文样例，Silero、FFmpeg、Opus 往返通过；EdgeTTS 合成固定测试句后，本地 ASR 回读结果归一化一致。EdgeTTS 在主 AI 容器默认不带代理的配置下也单独验证成功，无需给模型配置增加代理。
- 组件语音报告在 `.local/voice-verification/`，分别为 `asr.json`、`roundtrip.json`、`tts-direct.json`；这些报告记录样例与合成音频验证，实物语音验收另见下文。
- ESP32-S3 已确认底板 `ESP32-S3-AI-Adapter V1.01`；初次候选固件 `2.2.3`（ESP-IDF `v5.5.2`）刷写及 hash 校验通过，OLED 已显示文字。最新应用固件 `b339d87` 随后只写入 OTA 应用分区（app-only），回读校验通过，保留 NVS、原 Wi-Fi 配置、设备 UUID 与已有绑定。
- 输出音量 15 保存在 NVS，不能把刷写应用分区说成已调高音量。用户已确认听到针对真实说话的正常回答，麦克风 → ASR → Qwen → EdgeTTS → 扬声器的实物语音链路验收通过。
- 用户已确认 Wi-Fi 连接成功，硬件地址 `192.168.0.107` 与精确 MAC 邻居记录匹配，真实 OTA 返回激活码后已通过正常 Admin 流程绑定；不在文档保存临时激活码。服务端已记录设备 MQTT → AI 连接、MCP 工具、真实 ASR“小智小智”、Qwen 回复和 EdgeTTS 音频发送，用户确认实际听到正常回答，实物语音完整链路验收通过。
- 待机误显示“离线”的修复已部署：MQTT `3ed639a`、Admin `e806fbf` 区分设备 MQTT 在线与临时 AI 语音会话，保留 `isAlive` 原语义。真实设备待机响应为 `mqttConnected=true`、`exists=true`、`isAlive=false`、`voiceSessionActive=false`。本次仅更新 admin/mqtt/ai-server 三容器，均健康；MySQL、Redis、backend、task-api 容器未更换。Admin HTTP 200，实际下发的脚本已含新状态逻辑；未另做登录后视觉验收。MQTT 状态测试 1/1 通过，报告 `.local/status-fix-verification.json`。
- 此前配网时手机连入设备 AP 的地址为 `192.168.4.2`；强制使用 `wlan0` 请求配网页面返回 HTTP 200，默认蜂窝路由请求超时，因此曾指导用户手动关闭移动数据。本机工具修改手机移动数据的尝试被策略拦截，未执行。
- 原固件 `more-agent-ai-key-0.1.1` 的完整 16MB 备份仍保留在 `.local/esp32-backup/original-more-agent-ai-key-0.1.1-20261008.bin`，SHA256 为 `085BA1ADC21367ACDE979D83E59FDD0A8E891DF071ECB8B394EB72CF9D3DC0F2`，应用 checksum/hash 有效；可使用 `.local/Restore-OriginalEsp32.ps1` 恢复。刷写、屏幕及音量证据见 `.local/esp32-hardware-verification.json`。
- 邮箱最终范围已改为仅向本人发送测试邮件，全部扫描已取消。原任务 `f1f0c24e-0d7e-420b-ab83-f8cce0dd9999` 已完成真实 163 登录，北京时间 2026-10-08 04:03:52 只点击过一次发送；04:04:55 网易成功页显示“邮件发送成功”“已成功发送到收件人(1)”，主题为“小智 × Hermes 云端浏览器联调测试”。已取得原站发送成功证据，尚未复核收件箱送达，未再次发信。
- 原完整邮箱任务因 20 分钟 UI adapter 验证等待超时，仍为 `failed`，结果仅按部分证据记录，`send_state: uncertain` 保持原样，不能改称原任务全部完成或已核实送达。报告已标记 `scan_cancelled_by_user: true`，扫描读取数为 0，云端沙箱及关联测试资源已全部清理。12 小时扫描恢复源码 `9e7b409` / `72d3dc6` 仅保留在 im/runtime 的本地提交，未部署、未据此创建恢复任务；App 未提交的恢复按钮/API 改动已撤销，手机已回装保留部分报告显示的 `b1474a8`。
