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
   - **Docker 版本号**（如 `29.6.1`）
   - **目标架构**（`x86_64` 或 `aarch64`）
   - **国内镜像加速**（勾选后 Compose 走 ghproxy.com，GitHub action不用勾选，仅用于本地构建）
4. 等待构建完成，下载 Artifact 即可

构建产物为 `offline-docker-<version>-<arch>.zip`，解压后直接放到目标机器 `sudo bash install.sh`。
