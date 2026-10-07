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

模型目录以 `./Richard-ai-server/models:/app/models:ro` 挂载，AI 配置以 `./.local/ai-config.yaml:/app/data/.config.yaml:ro` 挂载；Dockerfile 将 `models`、`data` 和环境文件排除在镜像构建上下文外。模型资源校验记录在 `.local/sensevoice-resource-verification.json`。权重准备完成不代表语音推理通过；LLM/ASR/TTS 的实际模型选择及调用凭据需要后端启动后配置。

AI WebSocket 为 `9000`，HTTP 为 `9003`，MQTT TCP 为 `1883`，音频 UDP 为 `8884`，MQTT 管理 API 为 `8007`。`8884` 是 UDP 音频端口，并非 TLS MQTT 端口。

## 小智硬件局域网连接

默认所有可发布端口绑定本机回环。若硬件需经 Wi-Fi 连接，在 `.env.local` 将 `LOCAL_BIND_IP` 和 `LOCAL_ADVERTISE_IP` 都改为 Windows 实际局域网 IPv4，再运行启动脚本。Admin、Java、AI、MQTT 仅绑定该网卡地址；任务 API 与 MQTT 管理 API 仍只发布到回环。按实际需要在 Windows 防火墙放行设备所在私有网段，不要建立公网端口映射。

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
- SenseVoiceSmall 权重已下载，大小和 SHA256 已核对官方元数据；未加载执行模型。
- Compose 配置、PowerShell 语法及代理环境恢复检查通过；7 个服务容器健康。
- MySQL migrations、后端公共配置及 SM2 初始化通过，未登录模型接口拒绝访问；Admin 注册/登录、反向代理、任务监控和窄屏布局共 14 项验收通过。
- MQTT 健康检查同时检查 1883 和管理 API 8007，机器生成的 256 位十六进制签名密钥可用，日志不打印认证令牌。
- 后端镜像排除了原仓库 `application-dev.yml`，已核对最终 JAR 包含 local 配置且不包含 dev 配置。
- 语音功能验收通过：无网络临时容器加载 SenseVoiceSmall 并识别官方中文样例，Silero、FFmpeg、Opus 往返通过；EdgeTTS 合成固定测试句后，本地 ASR 回读结果归一化一致。EdgeTTS 在主 AI 容器默认不带代理的配置下也单独验证成功，无需给模型配置增加代理。
- 语音报告在 `.local/voice-verification/`，分别为 `asr.json`、`roundtrip.json`、`tts-direct.json`；没有采集用户麦克风音频。
- ESP32-S3 实际麦克风/喇叭和 App → Hermes 全链路未验收，云执行器未启动，未刷写硬件；不能用上述组件测试代替这些结果。
