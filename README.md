# Docker 离线安装 — 升级 & 构建工具

本项目包含两类工具：

## 1. 在线升级脚本

用于在**已联网**的目标机器上直接升级 Docker。

| 脚本 | 说明 |
|------|------|
| `upgrade_docker.sh` | 交互式选择 Docker 版本，备份旧版本后安装 |
| `uninstall_docker.sh` | 卸载 Docker 二进制及 systemd 服务（保留数据目录） |

### 使用

```bash
sudo bash upgrade_docker.sh
```

可选版本：18.09.9 / 19.03.15 / 20.10.24 / 23.0.6 / 24.0.6 / 29.6.1

---

## 2. 离线包构建脚本

用于在**开发机/CI**上提前下载并打包，交付给**离线客户环境**安装。

### 使用方法

```bash
# 交互式（选择版本）
bash build_offline.sh

# 指定版本 + 架构
bash build_offline.sh --version 29.6.1 --arch x86_64

# 国内加速（Compose 走 ghproxy.com）
bash build_offline.sh --version 29.6.1 --china-mirror

# 使用本地 compose 文件
bash build_offline.sh --version 29.6.1 --compose-file ./docker-compose-linux

# ARM64 (树莓派/鲲鹏)
bash build_offline.sh --version 29.6.1 --arch aarch64

# CI 非交互
bash build_offline.sh --version 29.6.1 --arch x86_64 --non-interactive
```

生成的 `offline-docker-<version>/` 目录拷贝到目标机器后：

```bash
cd offline-docker-29.6.1
sudo bash install.sh    # 安装
sudo bash uninstall.sh  # 卸载
```

### 下载源

| 组件 | 来源 |
|------|------|
| Docker Engine（静态二进制） | `https://download.docker.com/linux/static/stable/<arch>/` |
| Docker Compose | `https://github.com/docker/compose/releases/latest/` |

可通过环境变量覆盖：

```bash
export DOCKER_DOWNLOAD_BASE=https://internal-mirror.company.com/docker
export COMPOSE_DOWNLOAD_URL=https://internal-mirror.company.com/compose
export https_proxy=http://proxy:8080
```

---

## 3. GitHub Actions

本仓库包含一个 workflow，可在 GitHub 网页端手动触发构建离线包：

1. 进入仓库 **Actions** → **Build Offline Docker Package**
2. 点击 **Run workflow**
3. 填写参数：
   - **自定义 Docker 版本**（可留空；填写后优先生效）
   - **稳定版快捷选择**（未填写自定义版本时使用）
   - **目标架构**（`x86_64` 或 `aarch64`）
   - **国内镜像加速**（勾选后 Compose 走 ghproxy.com，GitHub action不用勾选，仅用于本地构建）
4. 等待构建完成，下载 Artifact 即可

构建产物为 `offline-docker-<version>-<arch>.tar.gz`，解压后直接放到目标机器 `sudo bash install.sh`。

离线包中还包含 `migrate-data-root.sh`，可在目标机器上交互式迁移 Docker 数据目录；脚本会询问新的目录位置，目录不存在时自动创建。

## 4. Cloudflare Worker 在线构建页面

仓库包含一个单 Worker 应用：Worker 同时提供构建页面和 `/api/jobs` 接口，实际编译仍由 GitHub Actions 执行。成功后 Action 会创建一个公开的 GitHub Release Asset，页面显示 Actions 运行链接和下载链接。

### 本地检查与部署

```bash
npm install
npm run check       # Wrangler dry-run
npm run dev         # 本地预览
npx wrangler secret put GITHUB_APP_PRIVATE_KEY
npx wrangler secret put GITHUB_APP_ID
npx wrangler secret put GITHUB_INSTALLATION_ID
npx wrangler secret put GITHUB_OWNER
npx wrangler secret put GITHUB_REPO
npx wrangler secret put TURNSTILE_SECRET
npx wrangler deploy
```

复制 `.dev.vars.example` 为本地 `.dev.vars` 后可用于本地开发；该文件不会提交。生产环境还需设置 `TURNSTILE_SITE_KEY`（可在 Wrangler 配置的 `[vars]` 中设置）。

GitHub App 需要安装到本仓库，并授予 Actions 读写、Contents 只读权限；Worker 只使用 App 安装令牌触发和查询工作流及 Release。仓库 Actions 使用自身的 `GITHUB_TOKEN` 创建 Release 和上传公开构建包。`cleanup-releases.yml` 每天删除 15 天前的离线包 Release。

### 运行限制

- 同时最多 1 个构建，最多排队 3 个任务。
- 同一版本、架构和镜像参数的任务会复用已有任务。
- 每个来源 IP 每小时最多提交 10 个新任务；重复参数会直接复用已有任务，不消耗额度。
- 配置 Turnstile 后，访客无需 GitHub 登录即可提交；未配置时仍有参数校验和限流，但建议生产环境启用 Turnstile。
