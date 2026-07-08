#!/bin/bash
##############################################################################
# Docker 在线升级脚本
# 适用于: Linux x86_64，需要 systemd
# 使用方法: sudo bash upgrade_docker.sh
#
# 与 upgrade_docker.sh (旧版) 区别:
#   - 内联版本列表 + 可选自定义版本
#   - 支持架构: x86_64 / aarch64
#   - 支持国内镜像加速
#   - 直接从 download.docker.com 下载，无需预置 tgz
##############################################################################

set -euo pipefail

# ---- 配置 ----
docker_download_base="https://download.docker.com/linux/static/stable"
compose_download_url="https://github.com/docker/compose/releases/latest/download"
target_arch="x86_64"
use_china_mirror=0

# curl 通用参数
curl_opts=(-fSL --connect-timeout 15 --retry 3 --retry-delay 5)
[ "${DOCKER_FORCE_IPV4:-0}" = "1" ] && curl_opts+=(-4)

tmp_dir=""

# ---- 清理陷阱 ----
cleanup() {
    [ -n "$tmp_dir" ] && [ -d "$tmp_dir" ] && rm -rf "$tmp_dir"
}
trap cleanup EXIT INT TERM

# ---- 版本号校验 ----
validate_version() {
    local ver="$1"
    if [[ ! "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$ ]]; then
        echo "[错误] 无效的版本号格式: ${ver}"
        return 1
    fi
    return 0
}

# ---- 参数解析 ----
while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch)         target_arch="$2"; shift 2 ;;
        --china-mirror) use_china_mirror=1; shift ;;
        --version)      arg_version="$2"; shift 2 ;;
        --help)
            echo "用法: sudo bash upgrade_docker.sh [选项]"
            echo ""
            echo "选项:"
            echo "  --version VER      直接指定 Docker 版本"
            echo "  --arch ARCH        目标架构: x86_64 | aarch64 (默认 x86_64)"
            echo "  --china-mirror     使用 ghproxy.com 代理下载 Compose"
            exit 0
            ;;
        *) echo "[错误] 未知参数: $1"; exit 1 ;;
    esac
done

case "$target_arch" in
    x86_64|aarch64) ;;
    *) echo "[错误] 不支持的架构: ${target_arch}（仅支持 x86_64 / aarch64）"; exit 1 ;;
esac

# ---- 常规配置 ----
echo "============================================"
echo " Docker 在线升级工具"
echo "============================================"
echo ""

# ---- 权限检查 ----
if [ "$(id -u)" -ne 0 ]; then
    echo "[错误] 请使用 root 用户或 sudo 运行此脚本！"
    exit 1
fi

# ---- 依赖检查 ----
for cmd in systemctl tar cp chmod curl gzip; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "[错误] 缺少必要的命令: $cmd"
        exit 1
    fi
done

# ---- 系统信息 ----
echo "[信息] 系统信息："
cat /etc/os-release 2>/dev/null | head -4 || true
uname -a
echo ""

# ---- 显示当前安装 ----
echo "[信息] 当前安装状态："
if docker -v >/dev/null 2>&1; then
    echo "  Docker: $(docker -v 2>&1)"
else
    echo "  Docker: 未安装"
fi
if docker-compose -v >/dev/null 2>&1; then
    echo "  Docker Compose: $(docker-compose -v 2>&1)"
else
    echo "  Docker Compose: 未安装"
fi
echo ""

# ---- 选择版本 ----
echo "可选版本:"
echo "  1) docker-29.6.1  (2026-06-26, 最新稳定)"
echo "  2) docker-28.4.1  (2025-11)"
echo "  3) docker-27.4.0  (2025-08)"
echo "  4) docker-26.1.4  (2024-10)"
echo "  c) 自定义版本（手动输入）"
echo ""

if [ -n "${arg_version:-}" ]; then
    selected_version="$arg_version"
else
    read -r -p "请选择版本号 [输入数字 / c]: " choice

    case "$choice" in
        1) selected_version="29.6.1" ;;
        2) selected_version="28.4.1" ;;
        3) selected_version="27.4.0" ;;
        4) selected_version="26.1.4" ;;
        c|C) read -r -p "请输入自定义 Docker 版本号（如 29.6.1）: " selected_version ;;
        *) echo "[错误] 无效的选择: $choice"; exit 1 ;;
    esac
fi

validate_version "$selected_version" || exit 1

echo ""
echo "============================================"
echo " 目标版本: Docker ${selected_version}"
echo " 目标架构: ${target_arch}"
if [ "$use_china_mirror" = "1" ]; then
    echo " 镜像模式: 国内加速"
fi
echo "============================================"
echo ""

read -r -p "确认升级？[Y/n] " confirm
case $confirm in
    [yY][eE][sS]|[yY]|"") ;;
    *) echo "已取消。"; exit 0 ;;
esac

# ---- 创建临时目录 ----
tmp_dir=$(mktemp -d -t docker-upgrade-XXXXXX)
packages_dir="${tmp_dir}/packages"
mkdir -p "$packages_dir"

# ---- 下载 Docker tgz ----
target_tgz="docker-${selected_version}.tgz"
tgz_path="${packages_dir}/${target_tgz}"
docker_url="${docker_download_base}/${target_arch}/${target_tgz}"

echo "[1/3] 下载 Docker ${selected_version}..."
echo "      URL: ${docker_url}"
curl "${curl_opts[@]}" -o "$tgz_path" "$docker_url" --progress-bar || {
    echo "[错误] 下载失败！请确认版本号正确: ${selected_version}"
    exit 1
}
echo "      ✓ 下载完成 ($(du -h "$tgz_path" 2>/dev/null | awk '{print $1}'))"

# gzip 完整性检测
if ! gzip -t "$tgz_path" 2>/dev/null; then
    echo "[错误] 下载的文件不是有效的 gzip 压缩包！"
    exit 1
fi

# SHA256 校验
checksum_url="${docker_url}.sha256"
expected=$(curl "${curl_opts[@]}" "$checksum_url" 2>/dev/null | awk '{print $1}') || true
if [ -n "$expected" ]; then
    actual=$(sha256sum "$tgz_path" | awk '{print $1}')
    if [ "$expected" != "$actual" ]; then
        echo "[错误] SHA256 校验失败！期望: ${expected}"
        exit 1
    fi
    echo "      SHA256 校验通过"
else
    echo "      [警告] 跳过 SHA256 校验"
fi
echo ""

# ---- 下载 Docker Compose ----
compose_url="${compose_download_url}/docker-compose-linux-${target_arch}"
if [ "$use_china_mirror" = "1" ]; then
    compose_url="https://ghproxy.com/${compose_download_url}/docker-compose-linux-${target_arch}"
fi

echo "[2/3] 下载 Docker Compose..."
curl "${curl_opts[@]}" -o "${packages_dir}/docker-compose-linux" "$compose_url" --progress-bar || {
    echo "[警告] Docker Compose 下载失败，跳过。"
}
if [ -f "${packages_dir}/docker-compose-linux" ]; then
    chmod 755 "${packages_dir}/docker-compose-linux"
    echo "      ✓ 下载完成 ($(du -h "${packages_dir}/docker-compose-linux" 2>/dev/null | awk '{print $1}'))"
fi
echo ""

# ---- 解压安装 Docker ----
echo "[3/3] 安装 Docker..."
cur_time=$(date "+%Y%m%d%H%M%S")

# 停止服务
systemctl stop docker.service 2>/dev/null || true
systemctl stop containerd.service 2>/dev/null || true

# 备份并替换二进制
tar -zxf "$tgz_path" -C "$packages_dir/"

known_bins=(docker dockerd docker-init docker-proxy containerd containerd-shim-runc-v2 ctr runc)
legacy_bins=(docker-runc docker-containerd docker-containerd-shim docker-containerd-ctr containerd-shim)

echo "[信息] 备份旧二进制..."
for f in "${known_bins[@]}" "${legacy_bins[@]}"; do
    [ -f "/usr/bin/${f}" ]      && mv -vf "/usr/bin/${f}"      "/usr/bin/${f}.bk.${cur_time}"
    [ -f "/usr/local/bin/${f}" ] && mv -vf "/usr/local/bin/${f}" "/usr/local/bin/${f}.bk.${cur_time}"
done

echo "[信息] 安装新二进制..."
for bin in "${known_bins[@]}"; do
    if [ -f "${packages_dir}/docker/${bin}" ]; then
        cp -fv "${packages_dir}/docker/${bin}" "/usr/bin/"
        chmod 755 "/usr/bin/${bin}"
    fi
done

# compose
if [ -f "${packages_dir}/docker-compose-linux" ]; then
    [ -f "/usr/bin/docker-compose" ] && mv -vf "/usr/bin/docker-compose" "/usr/bin/docker-compose.bk.${cur_time}"
    cp -fv "${packages_dir}/docker-compose-linux" "/usr/bin/docker-compose"
    chmod 755 "/usr/bin/docker-compose"
fi

# 更新 systemd 服务（使用内联配置）
mkdir -p /etc/systemd/system /etc/docker /etc/containerd

cat > /etc/systemd/system/docker.service << 'EOF'
[Unit]
Description=Docker Application Container Engine
Documentation=https://docs.docker.com
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/bin/dockerd
ExecReload=/bin/kill -s HUP $MAINPID
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity
TimeoutStartSec=0
Delegate=yes
KillMode=process
Restart=on-failure
StartLimitBurst=3
StartLimitInterval=60s

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/containerd.service << 'EOF'
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target

[Service]
ExecStartPre=/sbin/modprobe overlay
ExecStart=/usr/bin/containerd
Delegate=yes
KillMode=process
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity

[Install]
WantedBy=multi-user.target
EOF

# 保留现有 daemon.json
if [ ! -f "/etc/docker/daemon.json" ]; then
    cat > /etc/docker/daemon.json << 'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "3"
  },
  "live-restore": true,
  "data-root": "/var/lib/docker"
}
EOF
    echo "[信息] 创建默认 daemon.json"
else
    echo "[信息] 保留现有 /etc/docker/daemon.json"
fi

# 启动服务
systemctl daemon-reload

echo "[信息] 启动 containerd..."
systemctl restart containerd.service 2>/dev/null || systemctl start containerd.service || {
    echo "[错误] containerd 启动失败！"
    exit 1
}

# 等待 socket
for i in $(seq 1 30); do
    [ -S /run/containerd/containerd.sock ] && break
    sleep 1
done
if [ ! -S /run/containerd/containerd.sock ]; then
    echo "[错误] containerd 在 30 秒内未能就绪！"
    exit 1
fi

echo "[信息] 启动 Docker..."
systemctl restart docker.service 2>/dev/null || systemctl start docker.service || {
    echo "[错误] Docker 启动失败！"
    exit 1
}
systemctl enable containerd.service 2>/dev/null || true
systemctl enable docker.service 2>/dev/null || true

# ---- 验证 ----
echo ""
echo "============================================"
echo " 升级完成！"
echo "============================================"
echo ""
if ! docker -v >/dev/null 2>&1; then
    echo "[错误] Docker 升级失败！可回滚: /usr/bin/*.bk.${cur_time}"
    exit 1
fi
echo "--- Docker 版本 ---"
docker -v
docker-compose -v 2>/dev/null || true
containerd -v 2>/dev/null || true
runc -v 2>/dev/null || true
echo ""
echo "备份文件位于 /usr/bin/*.bk.${cur_time}"
echo ""
