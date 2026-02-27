# RAIOT 本地环境搭建（Windows）

## 1. 适用范围

本文用于在仓库根目录通过 `start-all.cmd` 一键启动以下服务：

- `Richard-admin`（默认 `8001`）
- `Richard-backend`（默认 `8002`）
- `Richard-ai-server`（默认 `9000` / `9003`）
- `Richard-mqtt-gateway`（默认 `1883` / `8884` / `8007`）

## 2. 必备软件

| 组件 | 推荐版本 | 说明 | 校验命令 |
| --- | --- | --- | --- |
| MySQL Server + Client | 8.0+ | 后端主数据库；`start-all.ps1` 会调用 `mysql.exe` 做建库检查 | `mysql --version` |
| Redis | 5.0+ | 后端缓存与会话 | `redis-server --version` |
| Node.js + npm | Node 18 LTS（npm 9+） | `Richard-admin` 与 `Richard-mqtt-gateway` | `node -v` / `npm -v` |
| Python | 3.10.x | `Richard-ai-server` 推荐环境 | `python --version` |
| JDK | 21 | `Richard-backend` 运行需要 | `java -version` |
| Maven | 3.9+ | 后端构建/启动；脚本可自动下载便携版 | `mvn -v` |
| Git | 最新稳定版 | 拉取子模块 | `git --version` |

## 3. 拉取代码与子模块

在仓库根目录执行：

```powershell
git submodule update --init --recursive
```

## 4. 数据库与缓存准备

### 4.1 MySQL

默认配置来自 `Richard-backend/src/main/resources/application-dev.yml`：

- Host: `127.0.0.1`
- Port: `3306`
- DB: `richard_esp32_server`
- User: `root`
- Password: `123456`

建库（可选，`start-all.ps1` 也会自动建库）：

```sql
CREATE DATABASE IF NOT EXISTS richard_esp32_server
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;
```

### 4.2 Redis

默认配置来自 `Richard-backend/src/main/resources/application-dev.yml`：

- Host: `127.0.0.1`
- Port: `6379`
- Password: 空
- DB index: `0`

快速检查：

```powershell
redis-cli -h 127.0.0.1 -p 6379 ping
```

期望返回：`PONG`。

### 4.3 Docker 快速启动（可选）

如果你更习惯容器方式，可直接启动 MySQL 与 Redis：

```powershell
docker run --name raiot-mysql `
  -e MYSQL_ROOT_PASSWORD=123456 `
  -e MYSQL_DATABASE=richard_esp32_server `
  -p 3306:3306 `
  -d mysql:8.0

docker run --name raiot-redis `
  -p 6379:6379 `
  -d redis:7-alpine
```

说明：

- 即使 MySQL 用 Docker 启动，`start-all.ps1` 仍需要本机可执行的 `mysql.exe` 来做建库检查。

## 5. 安装各子项目依赖

在仓库根目录依次执行：

```powershell
cd Richard-admin
npm install

cd ..\Richard-mqtt-gateway
npm install

cd ..\Richard-ai-server
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
```

说明：

- `Richard-ai-server/requirements.txt` 注释建议使用 Python `3.10`。
- 后端 Maven 依赖可在首次启动时自动下载，无需单独执行。

## 6. 根环境变量配置

根目录提供示例文件 `.env.raiot.example`。首次使用建议复制一份：

```powershell
Copy-Item .env.raiot.example .env.raiot -Force
```

重点检查以下字段：

- `RAIOT_MYSQL_HOST`
- `RAIOT_MYSQL_PORT`
- `RAIOT_MYSQL_USER`
- `RAIOT_MYSQL_PASSWORD`
- `RAIOT_HOST_IP`（`auto` 表示自动探测局域网 IP）

## 7. 一键启动

回到仓库根目录执行：

```powershell
.\start-all.cmd
```

常用参数：

```powershell
.\start-all.cmd -BackendProfile dev
.\start-all.cmd -RestartAiServer
.\start-all.cmd -SkipEsp32HintWindow
```

启动行为（默认）：

- 启动前检查并创建 MySQL 数据库（需要本机可执行 `mysql.exe`）
- 清理被占用的目标端口
- 启动后同步 `sys_params` 的 LAN 地址
- 同步 `Richard-esp32/sdkconfig` 的 OTA 地址

## 8. 启动后验证

可按下面清单确认：

1. 管理端：`http://localhost:8001/`
2. 后端文档：`http://localhost:8002/richard/doc.html`
3. 日志目录：`logs/start-all/<timestamp>/combined.log`
4. 端口监听检查：

```powershell
netstat -ano | findstr ":8001 :8002 :9000 :9003 :1883 :8884 :8007"
```

## 9. 可选：ESP-IDF 环境（固件编译）

如需在 `Richard-esp32` 编译/烧录，建议安装 ESP-IDF `5.5.x`，并配置：

- `IDF_PATH` 指向 `esp-idf-v5.5.x`
- `IDF_TOOLS_PATH` 指向 Espressif 工具目录（可选）

`start-all` 弹出的 ESP32 提示窗口会优先尝试加载 `ESP-IDF 5.5` 环境。

## 10. 常见问题

1. 报错 `mysql client not found`：
安装 MySQL Client，并把 `mysql.exe` 加入 `PATH`；如果 MySQL 在 Docker 中运行，本机仍需要 `mysql.exe` 供脚本调用。

2. Redis 连接失败：
确认 `redis-server` 已启动，且端口/密码与 `application-dev.yml` 一致。

3. Node 依赖安装失败：
先确认 `node -v` 是 18 LTS，再删除 `node_modules` 与锁文件后重装。

4. AI 服务启动失败（Python）：
使用 Python 3.10 重新创建环境，并重新执行 `pip install -r requirements.txt`。
