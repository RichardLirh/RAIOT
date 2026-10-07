# Windows 本地容器部署

Docker Desktop 和 WSL 已于 2026-10-07 安装。本次 WSL 首次启用 Virtual Machine Platform 后系统要求重启。保存工作并重启 Windows，然后打开 Docker Desktop。安装完成不代表容器已运行。

## 启动

在 RAIOT 根目录执行：

```powershell
.\Start-Local.ps1 -ValidateOnly
.\Start-Local.ps1
```

脚本首次生成 `.env.local` 的随机 MySQL、Redis、MQTT 凭据；`.local/task-tokens.json` 缺失时生成三类令牌，已有文件保持原样。文件被 Git 忽略，Windows ACL 限当前用户和 SYSTEM。脚本不读取旧 `.env.raiot`，不结束占用端口的进程，也不改写 ESP32 固件配置。

默认启动 MySQL、Redis、Java 后端、任务 API 和 Admin。数据库只使用 `raiot-local` 项目专属卷，未向宿主发布数据库或 Redis 端口。Java 通过 `application-local.yml` 使用现有 Liquibase changelog 建表；请勿导入旧数据库覆盖此卷。

| 服务 | 本机地址 | 说明 |
| --- | --- | --- |
| Admin | http://127.0.0.1:8001 | 管理后台与任务列表 |
| Java API | http://127.0.0.1:8002/richard | 首次注册流程沿用原仓实现 |
| 任务 API | http://127.0.0.1:8010 | 手机、Admin、Windows worker 共用任务状态 |

启动时端口若被本机开发服务器占用，先停止对应开发服务器后再执行。不要同时在同一端口启动容器版本与本机版本。任务 API 容器使用独立数据库卷；若之前使用过本机模式，其本机数据库不会自动复制到容器。

云端 Hermes 浏览器执行器仍单独运行在 Windows，按 `scripts/Start-AgentWorker.ps1` 说明接入任务 API。Kubeconfig 和模型密钥没有复制进 Docker 镜像。

## 语音 AI 与 MQTT

本机的 `SenseVoiceSmall/model.pt` 已于 2026-10-07 从官方 ModelScope 下载并验证，文件没有加入 Git。默认模型配置仍不含可用模型凭据，完成 Admin 配置后才能启动语音链路：

1. 本机权重已准备；在另一台机器上需从官方 [iic/SenseVoiceSmall](https://www.modelscope.cn/models/iic/SenseVoiceSmall) 下载 `model.pt` 到 `Richard-ai-server/models/SenseVoiceSmall/model.pt`。本次固定 revision 为 `70514a3da51f1160f51d18449dab6128bbd4928b`，大小 **936,291,369 bytes**，SHA256 为 `833ca2dcfdf8ec91bd4f31cfac36d6124e0c459074d5e909aec9cabe6204a3ea`，与官方 API 元数据一致。仓库已有两份模型配置在统一换行符后与官方一致，tokenizer 二进制校验一致；未执行下载模型附带代码。
2. 在 Admin 配置可用 LLM、TTS/ASR 参数。百炼密钥填配置时不要提交 Git。
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
- Compose 配置及 PowerShell 语法可在重启前校验。
- Docker 镜像构建、MySQL migrations、容器健康检查和硬件语音调用需在重启后实际验证；当前不能声称通过。
