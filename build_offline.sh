#!/bin/bash
##############################################################################
# Docker 离线安装包构建脚本
#
# 功能：选择版本/自定义版本 → 自动下载 → 生成 offline-docker-<version>/ 目录
# 使用方法:
#   bash build_offline.sh                        # 交互式
#   bash build_offline.sh --version 29.6.1       # 非交互式指定版本
#   bash build_offline.sh --china-mirror         # 使用国内代理加速
#   bash build_offline.sh --arch aarch64         # 构建 ARM64 架构包
#
# 环境变量（可选覆盖下载地址）:
#   DOCKER_DOWNLOAD_BASE    Docker tgz 下载基地址
#   COMPOSE_DOWNLOAD_URL    Docker Compose 下载完整 URL
#   https_proxy             curl 自动识别的 HTTPS 代理
#   DOCKER_FORCE_IPV4=1     强制 curl 使用 IPv4
##############################################################################

set -euo pipefail

# ---- 依赖检查（必须放在第一段可执行代码）----
for _cmd in cat cp curl du find gzip mkdir mktemp sed sort tar; do
    if ! command -v "$_cmd" >/dev/null 2>&1; then
        echo "[错误] 缺少必要的命令: $_cmd" >&2
        exit 1
    fi
done

# ---- 命令行参数 ----
non_interactive=0
arg_version=""
use_china_mirror=0
target_arch="x86_64"   # 默认架构
arg_compose_file=""    # 本地 compose 文件路径
skip_compose=0         # 跳过 compose 下载

usage() {
    echo "用法: bash build_offline.sh [选项]"
    echo ""
    echo "选项:"
    echo "  --version VER      指定 Docker 版本（跳过交互选择）"
    echo "  --arch ARCH        目标架构: x86_64 | aarch64 (默认 x86_64)"
    echo "  --china-mirror     使用国内代理加速 GitHub 下载"
    echo "  --compose-file F   使用本地 docker-compose 文件（跳过下载）"
    echo "  --skip-compose     不包含 docker-compose"
    echo "  --non-interactive  非交互模式（需配合 --version）"
    echo "  --help             显示此帮助信息"
    echo ""
    echo "环境变量:"
    echo "  DOCKER_DOWNLOAD_BASE     自定义 Docker tgz 下载基地址"
    echo "  COMPOSE_DOWNLOAD_URL     自定义 Docker Compose 下载 URL"
    echo "  https_proxy / http_proxy curl 自动识别的代理"
    echo "  DOCKER_FORCE_IPV4=1      强制 IPv4"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)    arg_version="$2"; shift 2 ;;
        --arch)       target_arch="$2"; shift 2 ;;
        --china-mirror) use_china_mirror=1; shift ;;
        --compose-file) arg_compose_file="$2"; shift 2 ;;
        --skip-compose) skip_compose=1; shift ;;
        --non-interactive) non_interactive=1; shift ;;
        --help)       usage ;;
        *)            echo "[错误] 未知参数: $1"; usage ;;
    esac
done

# 验证架构
case "$target_arch" in
    x86_64|aarch64) ;;
    *) echo "[错误] 不支持的架构: ${target_arch}（仅支持 x86_64 / aarch64）"; exit 1 ;;
esac

# ---- 全局配置 ----
script_dir="$(cd "$(dirname "$0")" && pwd)"

# 下载地址（可通过环境变量覆盖）
docker_download_base="${DOCKER_DOWNLOAD_BASE:-https://download.docker.com/linux/static/stable/${target_arch}}"
compose_download_url="${COMPOSE_DOWNLOAD_URL:-https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${target_arch}}"

# curl 通用参数
curl_opts=(-fSL --connect-timeout 15 --retry 3 --retry-delay 5 --retry-max-time 600)
[ "${DOCKER_FORCE_IPV4:-0}" = "1" ] && curl_opts+=(-4)

output_dir=""
selected_version=""
compose_version=""

# ---- 清理陷阱 ----
cleanup_on_interrupt() {
    echo ""
    echo "[中断] 正在清理不完整的输出目录..."
    [ -n "$output_dir" ] && [ -d "$output_dir" ] && rm -rf "$output_dir"
    exit 130
}
trap cleanup_on_interrupt INT TERM

# ---- 磁盘空间检查 ----
check_disk_space() {
    local required_mb=500
    if command -v df >/dev/null 2>&1; then
        local available_mb
        available_mb=$(df -m "$script_dir" 2>/dev/null | awk 'NR==2 {print $4}')
        if [ -n "$available_mb" ] && [ "$available_mb" -lt "$required_mb" ]; then
            echo "[错误] 磁盘空间不足！需要 ${required_mb}MB，可用 ${available_mb}MB"
            exit 1
        fi
    fi
}

# ---- 版本号校验 ----
validate_version() {
    local ver="$1"
    # Docker 版本格式: X.Y.Z 或 X.Y.Z-suffix
    if [[ ! "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$ ]]; then
        echo "[错误] 无效的版本号格式: ${ver}"
        echo "       版本号必须匹配格式: X.Y.Z 或 X.Y.Z-suffix"
        return 1
    fi
    return 0
}

# ---- sed 安全转义 ----
sed_escape() {
    # 转义 sed 替换字符串中的特殊字符
    printf '%s' "$1" | sed 's/[&/\]/\\&/g'
}

# ---- 检测 sed 风格 ----
detect_sed() {
    if sed --version 2>/dev/null | grep -q GNU; then
        echo "gnu"
    else
        echo "bsd"
    fi
}

sed_inplace() {
    local expr="$1"
    local file="$2"
    if [ "$sed_style" = "gnu" ]; then
        sed -i "$expr" "$file"
    else
        sed -i '' "$expr" "$file"
    fi
}

# ---- 扫描已知版本 ----
scan_known_versions() {
    local versions=()

    # 从 packages/docker-ce/ 扫描
    if [ -d "${script_dir}/packages/docker-ce" ]; then
        shopt -s nullglob
        for tgz in "${script_dir}/packages/docker-ce/"docker-*.tgz; do
            [ -f "$tgz" ] || continue
            local ver
            ver=$(basename "$tgz" .tgz | sed 's/^docker-//')
            # 只保留合法版本号格式的
            if [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$ ]]; then
                versions+=("$ver")
            fi
        done
        shopt -u nullglob
    fi

    # 从 offline-docker-* 目录扫描
    shopt -s nullglob
    for d in "${script_dir}/offline-docker-"*/; do
        [ -d "$d" ] || continue
        local name ver
        name=$(basename "$d")
        ver="${name#offline-docker-}"
        if [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$ ]] \
           && [[ ! " ${versions[*]} " =~ " ${ver} " ]]; then
            versions+=("$ver")
        fi
    done
    shopt -u nullglob

    # 去重并排序
    if [ ${#versions[@]} -gt 0 ]; then
        printf '%s\n' "${versions[@]}" | sort -t. -k1,1n -k2,2n -k3,3n -u
    fi
}

# ---- 查找本地缓存 ----
find_local_cache() {
    local tgz_name="$1"
    local found=""

    # 1) 先查 packages/docker-ce/
    if [ -f "${script_dir}/packages/docker-ce/${tgz_name}" ] \
       && [ -s "${script_dir}/packages/docker-ce/${tgz_name}" ]; then
        found="${script_dir}/packages/docker-ce/${tgz_name}"
    fi

    # 2) 再查所有 offline-docker-*/packages/
    if [ -z "$found" ]; then
        shopt -s nullglob
        for d in "${script_dir}/offline-docker-"*/; do
            local candidate="${d}packages/${tgz_name}"
            if [ -f "$candidate" ] && [ -s "$candidate" ]; then
                found="$candidate"
                break
            fi
        done
        shopt -u nullglob
    fi

    echo "$found"
}

# ---- SHA256 校验 ----
verify_sha256() {
    local tgz_path="$1"
    local tgz_url="$2"

    local checksum_url="${tgz_url}.sha256"
    local expected
    expected=$(curl "${curl_opts[@]}" "$checksum_url" 2>/dev/null | awk '{print $1}') || true

    if [ -z "$expected" ]; then
        echo "      [警告] 无法获取 SHA256 校验文件，跳过校验"
        return 0
    fi

    local actual
    if command -v sha256sum >/dev/null 2>&1; then
        actual=$(sha256sum "$tgz_path" | awk '{print $1}')
    elif command -v shasum >/dev/null 2>&1; then
        actual=$(shasum -a 256 "$tgz_path" | awk '{print $1}')
    else
        echo "      [警告] 系统无 sha256sum/shasum 命令，跳过校验"
        return 0
    fi

    if [ "$expected" != "$actual" ]; then
        echo "[错误] SHA256 校验失败！"
        echo "       期望: ${expected}"
        echo "       实际: ${actual}"
        return 1
    fi
    echo "      SHA256 校验通过"
    return 0
}

# ---- 下载 Docker tgz ----
download_docker_tgz() {
    local target_tgz="$1"
    local tgz_path="$2"
    local docker_url="${docker_download_base}/${target_tgz}"

    echo "[1/4] 下载 Docker ${selected_version} 二进制包..."
    echo "      URL: ${docker_url}"

    # 检查本地缓存
    local cached
    cached=$(find_local_cache "$target_tgz")
    if [ -n "$cached" ]; then
        echo "      ✓ 本地已有缓存，直接复制..."
        cp -v "$cached" "$tgz_path"
        verify_sha256 "$tgz_path" "$docker_url" || {
            echo "      [警告] 缓存文件 SHA256 校验失败，将重新下载"
            rm -f "$tgz_path"
            cached=""
        }
    fi

    if [ -z "$cached" ]; then
        curl "${curl_opts[@]}" -o "$tgz_path" "$docker_url" --progress-bar || {
            echo "[错误] Docker tgz 下载失败！"
            rm -f "$tgz_path"
            exit 1
        }
        echo ""
        echo "      ✓ 下载完成 ($(du -h "$tgz_path" 2>/dev/null | awk '{print $1}'))"

        # gzip 完整性快速检测
        if ! gzip -t "$tgz_path" 2>/dev/null; then
            echo "[错误] 下载的文件不是有效的 gzip 压缩包！可能下载了错误页面。"
            rm -f "$tgz_path"
            exit 1
        fi

        verify_sha256 "$tgz_path" "$docker_url" || {
            rm -f "$tgz_path"
            exit 1
        }
    fi
    echo ""
}

# ---- 下载 Docker Compose ----
download_compose() {
    local compose_path="$1"

    echo "[2/4] 下载最新 Docker Compose..."

    # 解析版本号（从 GitHub API）
    local fetched_version
    fetched_version=$(curl -fSL --connect-timeout 10 "https://api.github.com/repos/docker/compose/releases/latest" 2>/dev/null \
        | grep -oE '"tag_name" *: *"v[0-9]+\.[0-9]+\.[0-9]+"' | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1) || true

    if [ -n "$fetched_version" ]; then
        compose_version="$fetched_version"
        echo "      最新版本: ${compose_version}"
    fi

    curl "${curl_opts[@]}" -o "$compose_path" "$compose_download_url" --progress-bar || {
        echo "[错误] Docker Compose 下载失败！"
        rm -f "$compose_path"
        exit 1
    }
    echo ""

    # 验证是 ELF 二进制
    if ! file "$compose_path" 2>/dev/null | grep -q "ELF"; then
        echo "[错误] 下载的 docker-compose 不是有效的 ELF 可执行文件！"
        rm -f "$compose_path"
        exit 1
    fi

    chmod 755 "$compose_path"
    echo "      ✓ 下载完成 ($(du -h "$compose_path" 2>/dev/null | awk '{print $1}'))"

    # 如果 API 没拿到版本号，从二进制中提取
    if [ -z "$compose_version" ] && [ -f "$compose_path" ]; then
        compose_version=$(file "$compose_path" 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1) || true
    fi
    echo ""
}

# ---- 写配置文件（内联，不依赖外部模板）----
write_config_files() {
    echo "[3/4] 生成配置文件..."

    mkdir -p "${output_dir}/config"

    cat > "${output_dir}/config/docker.service" << 'EOF'
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

    cat > "${output_dir}/config/containerd.service" << 'EOF'
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

    cat > "${output_dir}/config/daemon.json" << 'EOF'
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

    echo "      ✓ docker.service"
    echo "      ✓ containerd.service"
    echo "      ✓ daemon.json"
    echo ""
}

# ---- 生成 install.sh ----
write_install_sh() {
    local safe_version
    safe_version=$(sed_escape "$selected_version")

    cat > "${output_dir}/install.sh" << 'INSTALL_EOF'
#!/bin/bash
##############################################################################
# Docker __VERSION__ 离线安装脚本
# 目标架构: __ARCH__
# 使用方法: sudo bash install.sh
##############################################################################

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
cur_time=$(date "+%Y%m%d%H%M%S")
target_version="__VERSION__"

echo "============================================"
echo " Docker __VERSION__ 离线安装"
echo " 目标架构: __ARCH__"
echo "============================================"
echo ""

# ---- 依赖检查 ----
if ! command -v systemctl >/dev/null 2>&1; then
    echo "[错误] 此脚本需要 systemd，但当前系统未检测到 systemctl。"
    exit 1
fi

for cmd in tar cp chmod mkdir sed; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "[错误] 缺少必要的命令: $cmd"
        exit 1
    fi
done

# ---- 权限检查 ----
if [ "$(id -u)" -ne 0 ]; then
    echo "[错误] 请使用 root 用户或 sudo 运行此脚本！"
    exit 1
fi

# ---- 显示系统信息 ----
echo "[信息] 系统信息："
cat /etc/os-release 2>/dev/null | head -4 || true
uname -a
echo ""

# ---- 备份旧的 Docker ----
backup_old_docker() {
    echo "============================================"
    echo " 检测到已有 Docker 安装，开始备份..."
    echo "============================================"

    # 停止现有服务
    systemctl stop docker.service 2>/dev/null || true
    systemctl stop containerd.service 2>/dev/null || true

    # 已知的二进制文件
    local modern_bins=(docker dockerd docker-init docker-proxy containerd containerd-shim-runc-v2 ctr runc)
    # 旧版本可能残留的文件
    local legacy_bins=(docker-runc docker-containerd docker-containerd-shim docker-containerd-ctr containerd-shim)

    for f in "${modern_bins[@]}" "${legacy_bins[@]}"; do
        [ -f "/usr/bin/${f}" ]      && mv -vf "/usr/bin/${f}"      "/usr/bin/${f}.bk.${cur_time}"
        [ -f "/usr/local/bin/${f}" ] && mv -vf "/usr/local/bin/${f}" "/usr/local/bin/${f}.bk.${cur_time}"
    done

    # docker-compose
    [ -f "/usr/bin/docker-compose" ]      && mv -vf "/usr/bin/docker-compose"      "/usr/bin/docker-compose.bk.${cur_time}"
    [ -f "/usr/local/bin/docker-compose" ] && mv -vf "/usr/local/bin/docker-compose" "/usr/local/bin/docker-compose.bk.${cur_time}"

    # systemd 服务文件
    local svc_paths=("/etc/systemd/system/docker.service" "/lib/systemd/system/docker.service" "/usr/lib/systemd/system/docker.service")
    for p in "${svc_paths[@]}"; do
        [ -f "$p" ] && mv -vf "$p" "${p}.bk.${cur_time}"
    done

    [ -f "/etc/systemd/system/containerd.service" ] && mv -vf "/etc/systemd/system/containerd.service" "/etc/systemd/system/containerd.service.bk.${cur_time}"
    [ -f "/lib/systemd/system/containerd.service" ]  && mv -vf "/lib/systemd/system/containerd.service"  "/lib/systemd/system/containerd.service.bk.${cur_time}"

    # 配置文件
    [ -f "/etc/containerd/config.toml" ] && mv -vf "/etc/containerd/config.toml" "/etc/containerd/config.toml.bk.${cur_time}"
    # daemon.json —— 只备份不移动，保留原文件供后续判断（install 覆盖，upgrade 保留）
    if [ -f "/etc/docker/daemon.json" ]; then
        cp -vf "/etc/docker/daemon.json" "/etc/docker/daemon.json.bk.${cur_time}"
        echo "[信息] 已备份 daemon.json → daemon.json.bk.${cur_time}"
    fi

    echo "[信息] 备份完成（后缀: .bk.${cur_time}）"
    echo ""
}

if [ -f "/usr/bin/docker" ] || [ -f "/usr/local/bin/docker" ]; then
    backup_old_docker
fi

# ---- 解压 Docker 二进制包 ----
echo "============================================"
echo " 解压 Docker ${target_version} 二进制包..."
echo "============================================"
tar -zxvf "${script_dir}/packages/docker-${target_version}.tgz" -C "${script_dir}/packages/"
echo ""

# ---- 安装 Docker 二进制文件（仅复制已知二进制）----
echo "============================================"
echo " 安装 Docker 二进制文件..."
echo "============================================"
known_bins=(docker dockerd docker-init docker-proxy containerd containerd-shim-runc-v2 ctr runc)
for bin in "${known_bins[@]}"; do
    if [ -f "${script_dir}/packages/docker/${bin}" ]; then
        cp -fv "${script_dir}/packages/docker/${bin}" "/usr/bin/"
        chmod 755 "/usr/bin/${bin}"
    fi
done

# 校验安装结果
for bin in docker dockerd containerd runc; do
    if [ ! -f "/usr/bin/${bin}" ]; then
        echo "[错误] 二进制文件未成功安装: /usr/bin/${bin}"
        exit 1
    fi
done
echo ""

# ---- 安装 docker-compose ----
echo "============================================"
echo " 安装 docker-compose..."
echo "============================================"
cp -fv "${script_dir}/packages/docker-compose-linux" "/usr/bin/docker-compose"
chmod 755 "/usr/bin/docker-compose"
echo ""

# ---- 配置 systemd 服务 ----
echo "============================================"
echo " 配置 systemd 服务..."
echo "============================================"
mkdir -p /etc/systemd/system /etc/docker /etc/containerd

cp -fv "${script_dir}/config/docker.service" "/etc/systemd/system/docker.service"
cp -fv "${script_dir}/config/containerd.service" "/etc/systemd/system/containerd.service"
echo ""

# ---- 配置 daemon.json ----
echo "============================================"
echo " 配置 Docker daemon.json..."
echo "============================================"
cp -fv "${script_dir}/config/daemon.json" "/etc/docker/daemon.json"
echo ""

# ---- 启动服务 ----
echo "============================================"
echo " 启动 Docker 服务..."
echo "============================================"
systemctl daemon-reload

echo "[信息] 启动 containerd..."
if systemctl start containerd.service; then
    echo "      ✓ containerd 已启动"
else
    echo "[错误] containerd 启动失败！"
    echo "       查看日志: journalctl -xeu containerd.service"
    exit 1
fi

# 等待 containerd socket 就绪
echo "[信息] 等待 containerd socket 就绪..."
for i in $(seq 1 30); do
    if [ -S /run/containerd/containerd.sock ]; then
        echo "      ✓ containerd socket 已就绪"
        break
    fi
    sleep 1
done

if [ ! -S /run/containerd/containerd.sock ]; then
    echo "[错误] containerd 在 30 秒内未能就绪！"
    echo "       查看日志: journalctl -xeu containerd.service"
    exit 1
fi

echo "[信息] 启动 Docker..."
if systemctl start docker.service; then
    echo "      ✓ Docker 已启动"
    systemctl enable containerd.service 2>/dev/null || true
    systemctl enable docker.service 2>/dev/null || true
else
    echo "[错误] Docker 启动失败！"
    echo "       查看日志: journalctl -xeu docker.service"
    exit 1
fi
echo ""

# ---- 验证安装 ----
echo "============================================"
echo " 验证安装..."
echo "============================================"
echo ""

if ! docker -v >/dev/null 2>&1; then
    echo "[错误] Docker 安装验证失败！docker 命令不可用。"
    exit 1
fi
echo "--- Docker 版本 ---"
docker -v

if ! docker-compose -v >/dev/null 2>&1; then
    echo "[警告] docker-compose 命令不可用"
else
    echo "--- Docker Compose 版本 ---"
    docker-compose -v
fi

echo "--- containerd 版本 ---"
containerd -v 2>/dev/null || echo "(containerd 命令未找到)"
echo "--- runc 版本 ---"
runc -v 2>/dev/null || echo "(runc 命令未找到)"

if ! systemctl is-active --quiet docker.service; then
    echo "[警告] Docker 服务处于非活跃状态！"
else
    echo "--- Docker 服务状态 ---"
    systemctl status docker.service --no-pager -l 2>/dev/null | head -10
fi

echo ""
echo "============================================"
echo " Docker __VERSION__ (__ARCH__) 安装完成！"
echo "============================================"
INSTALL_EOF

    # 替换占位符
    sed_inplace "s|__VERSION__|${safe_version}|g" "${output_dir}/install.sh"
    sed_inplace "s|__ARCH__|${target_arch}|g" "${output_dir}/install.sh"
    chmod +x "${output_dir}/install.sh"
}

# ---- 生成 upgrade.sh ----
write_upgrade_sh() {
    local safe_version
    safe_version=$(sed_escape "$selected_version")

    cat > "${output_dir}/upgrade.sh" << 'UPGRADE_EOF'
#!/bin/bash
##############################################################################
# Docker __VERSION__ 升级脚本
# 目标架构: __ARCH__
# 使用方法: sudo bash upgrade.sh
#
# 与 install.sh 区别：保留现有 /etc/docker/daemon.json 不变
##############################################################################

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
cur_time=$(date "+%Y%m%d%H%M%S")
target_version="__VERSION__"

echo "============================================"
echo " Docker 升级到 __VERSION__"
echo " 目标架构: __ARCH__"
echo "============================================"
echo ""

# ---- 依赖检查 ----
if ! command -v systemctl >/dev/null 2>&1; then
    echo "[错误] 此脚本需要 systemd，但当前系统未检测到 systemctl。"
    exit 1
fi

for cmd in tar cp chmod mkdir sed; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "[错误] 缺少必要的命令: $cmd"
        exit 1
    fi
done

# ---- 权限检查 ----
if [ "$(id -u)" -ne 0 ]; then
    echo "[错误] 请使用 root 用户或 sudo 运行此脚本！"
    exit 1
fi

# ---- 检查已有安装 ----
if ! [ -f "/usr/bin/docker" ] && ! [ -f "/usr/local/bin/docker" ]; then
    echo "[警告] 未检测到已有 Docker 安装，建议使用 install.sh 进行全新安装。"
    read -r -p "继续升级安装？[y/N] " cont
    case $cont in
        [yY][eE][sS]|[yY]) ;;
        *) echo "已取消。"; exit 0 ;;
    esac
fi

# ---- 显示系统信息 ----
echo "[信息] 系统信息："
cat /etc/os-release 2>/dev/null | head -4 || true
uname -a
echo ""

# ---- 显示当前版本 ----
if docker -v >/dev/null 2>&1; then
    echo "[信息] 当前 Docker 版本:"
    docker -v
fi
echo ""

# ---- 备份旧的 Docker ----
echo "============================================"
echo " 备份旧版 Docker..."
echo "============================================"

# 停止现有服务
systemctl stop docker.service 2>/dev/null || true
systemctl stop containerd.service 2>/dev/null || true

# 已知的二进制文件
modern_bins=(docker dockerd docker-init docker-proxy containerd containerd-shim-runc-v2 ctr runc)
legacy_bins=(docker-runc docker-containerd docker-containerd-shim docker-containerd-ctr containerd-shim)

for f in "${modern_bins[@]}" "${legacy_bins[@]}"; do
    [ -f "/usr/bin/${f}" ]      && mv -vf "/usr/bin/${f}"      "/usr/bin/${f}.bk.${cur_time}"
    [ -f "/usr/local/bin/${f}" ] && mv -vf "/usr/local/bin/${f}" "/usr/local/bin/${f}.bk.${cur_time}"
done

# docker-compose
[ -f "/usr/bin/docker-compose" ]      && mv -vf "/usr/bin/docker-compose"      "/usr/bin/docker-compose.bk.${cur_time}"
[ -f "/usr/local/bin/docker-compose" ] && mv -vf "/usr/local/bin/docker-compose" "/usr/local/bin/docker-compose.bk.${cur_time}"

# systemd 服务文件
for p in /etc/systemd/system/docker.service /lib/systemd/system/docker.service /usr/lib/systemd/system/docker.service \
         /etc/systemd/system/containerd.service /lib/systemd/system/containerd.service; do
    [ -f "$p" ] && mv -vf "$p" "${p}.bk.${cur_time}"
done

# containerd 配置（只备份，不覆盖）
[ -f "/etc/containerd/config.toml" ] && mv -vf "/etc/containerd/config.toml" "/etc/containerd/config.toml.bk.${cur_time}"

# daemon.json —— 只备份不移走（install 覆盖，upgrade 保留）
if [ -f "/etc/docker/daemon.json" ]; then
    cp -vf "/etc/docker/daemon.json" "/etc/docker/daemon.json.bk.${cur_time}"
    echo "[信息] 已备份 daemon.json → daemon.json.bk.${cur_time}"
fi

echo "[信息] 备份完成（后缀: .bk.${cur_time}）"
echo ""

# ---- 解压 Docker 二进制包 ----
echo "============================================"
echo " 解压 Docker ${target_version} 二进制包..."
echo "============================================"
tar -zxvf "${script_dir}/packages/docker-${target_version}.tgz" -C "${script_dir}/packages/"
echo ""

# ---- 安装 Docker 二进制文件 ----
echo "============================================"
echo " 安装 Docker 二进制文件..."
echo "============================================"
known_bins=(docker dockerd docker-init docker-proxy containerd containerd-shim-runc-v2 ctr runc)
for bin in "${known_bins[@]}"; do
    if [ -f "${script_dir}/packages/docker/${bin}" ]; then
        cp -fv "${script_dir}/packages/docker/${bin}" "/usr/bin/"
        chmod 755 "/usr/bin/${bin}"
    fi
done

for bin in docker dockerd containerd runc; do
    if [ ! -f "/usr/bin/${bin}" ]; then
        echo "[错误] 二进制文件未成功安装: /usr/bin/${bin}"
        exit 1
    fi
done
echo ""

# ---- 安装 docker-compose ----
echo "============================================"
echo " 安装 docker-compose..."
echo "============================================"
cp -fv "${script_dir}/packages/docker-compose-linux" "/usr/bin/docker-compose"
chmod 755 "/usr/bin/docker-compose"
echo ""

# ---- 配置 systemd 服务（更新）----
echo "============================================"
echo " 更新 systemd 服务文件..."
echo "============================================"
mkdir -p /etc/systemd/system /etc/docker /etc/containerd

cp -fv "${script_dir}/config/docker.service" "/etc/systemd/system/docker.service"
cp -fv "${script_dir}/config/containerd.service" "/etc/systemd/system/containerd.service"

# 保留现有 daemon.json，不存在则创建默认配置
if [ ! -f "/etc/docker/daemon.json" ]; then
    echo "[信息] daemon.json 不存在，创建默认配置..."
    cp -fv "${script_dir}/config/daemon.json" "/etc/docker/daemon.json"
else
    echo "[信息] 保留现有 /etc/docker/daemon.json（跳过覆盖）"
fi
echo ""

# ---- 重启服务 ----
echo "============================================"
echo " 重启 Docker 服务..."
echo "============================================"
systemctl daemon-reload

echo "[信息] 启动 containerd..."
if systemctl start containerd.service; then
    echo "      ✓ containerd 已启动"
else
    echo "[错误] containerd 启动失败！"
    echo "       查看日志: journalctl -xeu containerd.service"
    exit 1
fi

# 等待 containerd socket 就绪
echo "[信息] 等待 containerd socket 就绪..."
for i in $(seq 1 30); do
    if [ -S /run/containerd/containerd.sock ]; then
        echo "      ✓ containerd socket 已就绪"
        break
    fi
    sleep 1
done

if [ ! -S /run/containerd/containerd.sock ]; then
    echo "[错误] containerd 在 30 秒内未能就绪！"
    exit 1
fi

echo "[信息] 重启 Docker..."
if systemctl restart docker.service; then
    echo "      ✓ Docker 已重启"
    systemctl enable containerd.service 2>/dev/null || true
    systemctl enable docker.service 2>/dev/null || true
else
    echo "[警告] restart 失败，尝试 start..."
    if systemctl start docker.service; then
        echo "      ✓ Docker 已启动"
    else
        echo "[错误] Docker 启动失败！"
        echo "       查看日志: journalctl -xeu docker.service"
        exit 1
    fi
fi
echo ""

# ---- 验证安装 ----
echo "============================================"
echo " 验证升级结果..."
echo "============================================"
echo ""

if ! docker -v >/dev/null 2>&1; then
    echo "[错误] 升级失败！docker 命令不可用。"
    echo "       可以回滚备份文件: /usr/bin/*.bk.${cur_time}"
    exit 1
fi
echo "--- Docker 版本 ---"
docker -v

if ! docker-compose -v >/dev/null 2>&1; then
    echo "[警告] docker-compose 命令不可用"
else
    echo "--- Docker Compose 版本 ---"
    docker-compose -v
fi

echo "--- containerd 版本 ---"
containerd -v 2>/dev/null || echo "(containerd 命令未找到)"
echo "--- runc 版本 ---"
runc -v 2>/dev/null || echo "(runc 命令未找到)"

if ! systemctl is-active --quiet docker.service; then
    echo "[警告] Docker 服务处于非活跃状态！"
else
    echo "--- Docker 服务状态 ---"
    systemctl status docker.service --no-pager -l 2>/dev/null | head -10
fi

echo ""
echo "============================================"
echo " Docker 升级到 __VERSION__ (__ARCH__) 完成！"
echo " 旧版本文件备份在 /usr/bin/*.bk.${cur_time}"
echo "============================================"
UPGRADE_EOF

    sed_inplace "s|__VERSION__|${safe_version}|g" "${output_dir}/upgrade.sh"
    sed_inplace "s|__ARCH__|${target_arch}|g"    "${output_dir}/upgrade.sh"
    chmod +x "${output_dir}/upgrade.sh"
}

# ---- 生成 uninstall.sh ----
write_uninstall_sh() {
    local safe_version
    safe_version=$(sed_escape "$selected_version")

    cat > "${output_dir}/uninstall.sh" << 'UNINSTALL_EOF'
#!/bin/bash
##############################################################################
# Docker __VERSION__ 卸载脚本
# 目标架构: __ARCH__
# 使用方法: sudo bash uninstall.sh
##############################################################################

set -euo pipefail

cur_time=$(date "+%Y%m%d%H%M%S")

echo "============================================"
echo " Docker __VERSION__ (__ARCH__) 卸载"
echo "============================================"
echo ""
echo "警告: 此操作将删除 Docker 二进制文件和服务配置"
echo "注意: 不会删除 Docker 数据目录（如 /var/lib/docker）"
echo ""

read -r -p "确认卸载? [y/N] " input
case $input in
    [yY][eE][sS]|[yY]) ;;
    *) echo "已取消卸载。"; exit 0 ;;
esac

# ---- 停止服务 ----
echo "[信息] 停止 Docker 服务..."
systemctl stop docker.service 2>/dev/null || true
systemctl stop containerd.service 2>/dev/null || true
systemctl disable docker.service 2>/dev/null || true
systemctl disable containerd.service 2>/dev/null || true

# ---- 删除二进制文件 ----
echo "[信息] 删除 Docker 二进制文件..."
bin_files=(
    containerd containerd-shim containerd-shim-runc-v2 ctr
    docker docker-init docker-proxy dockerd runc docker-compose
    docker-runc docker-containerd docker-containerd-shim docker-containerd-ctr
)
for f in "${bin_files[@]}"; do
    rm -fv "/usr/bin/${f}"
    rm -fv "/usr/local/bin/${f}"
done

# ---- 删除 systemd 服务 ----
echo "[信息] 删除 systemd 服务文件..."
rm -fv /etc/systemd/system/docker.service
rm -fv /etc/systemd/system/containerd.service
rm -fv /lib/systemd/system/containerd.service
rm -fv /lib/systemd/system/docker.service
rm -fv /usr/lib/systemd/system/docker.service

# ---- 备份并删除配置 ----
echo "[信息] 备份并删除配置文件..."
[ -f "/etc/docker/daemon.json" ]     && mv -vf "/etc/docker/daemon.json"     "/etc/docker/daemon.json.bk.${cur_time}"
[ -f "/etc/containerd/config.toml" ] && mv -vf "/etc/containerd/config.toml" "/etc/containerd/config.toml.bk.${cur_time}"

# ---- 重载 ----
systemctl daemon-reload

echo ""
echo "============================================"
echo " 卸载完成！"
echo ""
echo " 提示:"
echo "   - Docker 数据目录未被删除（/var/lib/docker）"
echo "   - 配置文件已备份为 .bk.${cur_time} 后缀"
echo "============================================"
UNINSTALL_EOF

    sed_inplace "s|__VERSION__|${safe_version}|g" "${output_dir}/uninstall.sh"
    sed_inplace "s|__ARCH__|${target_arch}|g" "${output_dir}/uninstall.sh"
    chmod +x "${output_dir}/uninstall.sh"
}

# ---- 生成 migrate-data-root.sh ----
write_migrate_data_root_sh() {
    write_migrate_data_root_sh_v2
}

# ---- 生成 README.md ----
write_readme() {
    write_readme_v2
    return

    local safe_version safe_arch compose_display
    safe_version=$(sed_escape "$selected_version")
    safe_arch="$target_arch"

    if [ -n "$compose_version" ]; then
        compose_display="$compose_version"
    else
        compose_display="latest (请查看 https://github.com/docker/compose/releases)"
    fi

    cat > "${output_dir}/README.md" << README_EOF
# Docker __DOCKER_VERSION__ 离线安装包

## 适用环境

- **架构**: __ARCH__
- **操作系统**: Ubuntu 22.04 / CentOS 7 等支持 systemd 的 Linux
- **Docker 版本**: __DOCKER_VERSION__
- **Docker Compose**: __COMPOSE_VERSION__

## 目录结构

\`\`\`
offline-docker-__DOCKER_VERSION__/
├── install.sh                          # 安装脚本
├── uninstall.sh                        # 卸载脚本
├── README.md                           # 本文件
├── config/
│   ├── daemon.json                     # Docker daemon 配置
│   ├── docker.service                  # Docker systemd 服务
│   └── containerd.service              # containerd systemd 服务
└── packages/
    ├── docker-__DOCKER_VERSION__.tgz        # Docker 静态二进制包
    └── docker-compose-linux            # Docker Compose __COMPOSE_VERSION__
\`\`\`

## 使用方法

### 安装

\`\`\`bash
# 1. 将整个 offline-docker-__DOCKER_VERSION__ 目录拷贝到目标机器
# 2. 进入目录并执行安装脚本
cd offline-docker-__DOCKER_VERSION__
sudo bash install.sh
\`\`\`

### 卸载

\`\`\`bash
sudo bash uninstall.sh
\`\`\`

## daemon.json 配置说明

使用简化的默认配置:
- 日志驱动: json-file (单文件最大 100M，保留 3 个)
- live-restore: 开启（Docker daemon 重启时容器保持运行）
- 数据目录: /var/lib/docker
- 未配置 registry-mirrors 和代理，客户可按需自行添加

## 注意事项

1. 安装脚本**需要 root 权限**执行
2. 如果目标机器已安装 Docker，脚本会自动备份旧文件（\`.bk.时间戳\` 后缀）
3. 安装完成后 Docker 服务会自动启动并设为开机自启
4. 卸载脚本**不会删除** Docker 数据目录（/var/lib/docker），仅移除二进制和 systemd 配置
README_EOF

    sed_inplace "s|__DOCKER_VERSION__|${safe_version}|g" "${output_dir}/README.md"
    sed_inplace "s|__ARCH__|${safe_arch}|g"                "${output_dir}/README.md"
    sed_inplace "s|__COMPOSE_VERSION__|${compose_display}|g" "${output_dir}/README.md"
}

# ---- Generate migrate-data-root.sh (v2) ----
write_migrate_data_root_sh_v2() {
    cat > "${output_dir}/migrate-data-root.sh" << 'MIGRATE_EOF'
#!/bin/bash
##############################################################################
# Docker data-root migration script
# Usage: sudo bash migrate-data-root.sh
##############################################################################

set -euo pipefail

cur_time=$(date "+%Y%m%d%H%M%S")
daemon_json="${DOCKER_DAEMON_JSON:-/etc/docker/daemon.json}"
docker_data_root_default="${DOCKER_DATA_ROOT_DEFAULT:-/var/lib/docker}"

echo "============================================"
echo " Docker data-root migration"
echo "============================================"
echo ""

if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] Run this script with root or sudo."
    exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
    echo "[ERROR] systemctl is required for a safe Docker data-root migration."
    exit 1
fi

for cmd in awk cp dirname find grep mkdir mktemp mv rm sed; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "[ERROR] Missing required command: $cmd"
        exit 1
    fi
done

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

detect_current_data_root() {
    if [ -f "$daemon_json" ]; then
        awk -F'"' '/"data-root"/ {print $4; exit}' "$daemon_json"
    fi
}

write_daemon_json_with_data_root() {
    local target_root="$1"
    local escaped_target
    local tmp_json
    escaped_target=$(json_escape "$target_root")
    tmp_json=$(mktemp)

    if [ -f "$daemon_json" ]; then
        awk -v new_root="$escaped_target" '
            BEGIN { replaced = 0 }
            {
                if (!replaced && $0 ~ /"data-root"[[:space:]]*:/) {
                    sub(/"data-root"[[:space:]]*:[[:space:]]*"[^"]*"/, "\"data-root\": \"" new_root "\"")
                    replaced = 1
                }
                lines[NR] = $0
            }
            END {
                if (NR == 0) {
                    print "{"
                    print "  \"data-root\": \"" new_root "\""
                    print "}"
                    exit
                }

                if (replaced) {
                    for (i = 1; i <= NR; i++) {
                        print lines[i]
                    }
                    exit
                }

                inserted = 0
                for (i = 1; i <= NR; i++) {
                    print lines[i]
                    if (!inserted && lines[i] ~ /^[[:space:]]*\{[[:space:]]*$/) {
                        next_line = ""
                        for (j = i + 1; j <= NR; j++) {
                            if (lines[j] ~ /^[[:space:]]*$/) {
                                continue
                            }
                            next_line = lines[j]
                            break
                        }
                        if (next_line != "" && next_line !~ /^[[:space:]]*}/) {
                            print "  \"data-root\": \"" new_root "\"," 
                        } else {
                            print "  \"data-root\": \"" new_root "\""
                        }
                        inserted = 1
                    }
                }
            }
        ' "$daemon_json" > "$tmp_json"
    else
        cat > "$tmp_json" << EOF
{
  "data-root": "$target_root"
}
EOF
    fi

    mv "$tmp_json" "$daemon_json"
}

current_data_root="$(detect_current_data_root || true)"
current_data_root="${current_data_root:-$docker_data_root_default}"
current_data_root=$(printf '%s' "$current_data_root" | sed 's:/*$::')

echo "[INFO] Current Docker data directory: ${current_data_root}"
read -r -p "Enter new Docker data directory (for example /data/docker): " target_data_root

if [ -z "${target_data_root}" ]; then
    echo "[ERROR] Target directory cannot be empty."
    exit 1
fi

case "$target_data_root" in
    /*) ;;
    *)
        echo "[ERROR] Target directory must be an absolute path."
        exit 1
        ;;
esac

target_data_root=$(printf '%s' "$target_data_root" | sed 's:/*$::')

if [ "$target_data_root" = "$current_data_root" ]; then
    echo "[INFO] Target directory matches the current data directory. Nothing to do."
    exit 0
fi

if [ ! -d "$current_data_root" ]; then
    echo "[ERROR] Current data directory does not exist: ${current_data_root}"
    exit 1
fi

if [ ! -d "$target_data_root" ]; then
    echo "[INFO] Target directory does not exist. Creating: ${target_data_root}"
    mkdir -p "$target_data_root"
fi

if [ -n "$(find "$target_data_root" -mindepth 1 -print -quit 2>/dev/null)" ]; then
    echo "[WARN] Target directory is not empty: ${target_data_root}"
    echo "[WARN] Docker data will be copied into this directory and files may be overwritten."
    read -r -p "Continue? [y/N] " confirm_nonempty
    case "$confirm_nonempty" in
        [yY][eE][sS]|[yY]) ;;
        *) echo "Cancelled."; exit 0 ;;
    esac
fi

echo ""
echo "Migration plan:"
echo "  Current directory: ${current_data_root}"
echo "  Target directory:  ${target_data_root}"
echo "  Mode: stop services, copy data, update daemon.json, restart Docker"
echo ""

read -r -p "Proceed with migration? [y/N] " confirm_start
case "$confirm_start" in
    [yY][eE][sS]|[yY]) ;;
    *) echo "Cancelled."; exit 0 ;;
esac

mkdir -p "$(dirname "$daemon_json")"

backup_daemon_json=""
if [ -f "$daemon_json" ]; then
    backup_daemon_json="${daemon_json}.bk.${cur_time}"
    cp -vf "$daemon_json" "$backup_daemon_json"
fi

rollback_needed=1
rollback() {
    local status=$?
    if [ "$rollback_needed" -eq 1 ]; then
        echo "[WARN] Migration failed. Restoring previous Docker configuration..."
        if [ -n "$backup_daemon_json" ] && [ -f "$backup_daemon_json" ]; then
            cp -vf "$backup_daemon_json" "$daemon_json" || true
        elif [ -f "$daemon_json" ]; then
            rm -f "$daemon_json" || true
        fi
        systemctl daemon-reload || true
        systemctl start containerd.service || true
        systemctl start docker.service || true
    fi
    exit "$status"
}
trap rollback EXIT

echo "[INFO] Stopping Docker and containerd..."
systemctl stop docker.service 2>/dev/null || true
systemctl stop containerd.service 2>/dev/null || true

echo "[INFO] Copying Docker data..."
if command -v rsync >/dev/null 2>&1; then
    rsync -aHAX --delete --info=progress2 "${current_data_root}/" "${target_data_root}/"
else
    echo "[INFO] rsync not found. Falling back to cp -a without progress output."
    cp -a "${current_data_root}/." "$target_data_root/"
fi

if [ ! -e "$target_data_root/image" ] && [ ! -e "$target_data_root/containers" ] && [ -n "$(find "$current_data_root" -mindepth 1 -print -quit 2>/dev/null)" ]; then
    echo "[ERROR] Target directory does not appear to contain copied Docker data."
    exit 1
fi

write_daemon_json_with_data_root "$target_data_root"

echo "[INFO] Starting containerd and Docker..."
systemctl daemon-reload
systemctl start containerd.service
systemctl start docker.service

echo "[INFO] Verifying Docker Root Dir..."
docker_root_dir=$(docker info 2>/dev/null | awk -F': ' '/Docker Root Dir/ {print $2; exit}') || true
if [ "$docker_root_dir" != "$target_data_root" ]; then
    echo "[ERROR] Verification failed. Current Docker Root Dir: ${docker_root_dir:-unknown}"
    echo "        Check: journalctl -xeu docker.service"
    exit 1
fi

rollback_needed=0
trap - EXIT

echo ""
echo "============================================"
echo " Migration completed"
echo " New data directory: ${target_data_root}"
echo " Original directory preserved: ${current_data_root}"
if [ -n "$backup_daemon_json" ]; then
    echo " daemon.json backup: ${backup_daemon_json}"
fi
echo "============================================"
MIGRATE_EOF

    chmod +x "${output_dir}/migrate-data-root.sh"
}

# ---- Generate README.md (v2) ----
write_readme_v2() {
    local safe_version safe_arch compose_display
    safe_version=$(sed_escape "$selected_version")
    safe_arch="$target_arch"

    if [ -n "$compose_version" ]; then
        compose_display="$compose_version"
    else
        compose_display="latest (see https://github.com/docker/compose/releases)"
    fi

    cat > "${output_dir}/README.md" << README_EOF
# Docker __DOCKER_VERSION__ Offline Package

## Environment

- **Architecture**: __ARCH__
- **OS**: Linux with \`systemd\` support, such as Ubuntu 22.04 or CentOS 7
- **Docker Version**: __DOCKER_VERSION__
- **Docker Compose**: __COMPOSE_VERSION__

## Directory Layout

\`\`\`text
offline-docker-__DOCKER_VERSION__/
|-- install.sh
|-- upgrade.sh
|-- migrate-data-root.sh
|-- uninstall.sh
|-- README.md
|-- config/
|   |-- daemon.json
|   |-- docker.service
|   \`-- containerd.service
\`-- packages/
    |-- docker-__DOCKER_VERSION__.tgz
    \`-- docker-compose-linux
\`\`\`

## Usage

### Install

\`\`\`bash
cd offline-docker-__DOCKER_VERSION__
sudo bash install.sh
\`\`\`

### Upgrade

\`\`\`bash
cd offline-docker-__DOCKER_VERSION__
sudo bash upgrade.sh
\`\`\`

### Migrate Docker Data Directory

\`\`\`bash
cd offline-docker-__DOCKER_VERSION__
sudo bash migrate-data-root.sh
\`\`\`

The migration script prompts for a new Docker data directory, creates it if needed, copies the current Docker data, updates \`/etc/docker/daemon.json\`, restarts Docker, and verifies the new \`Docker Root Dir\`. The original data directory is preserved for rollback.

### Uninstall

\`\`\`bash
sudo bash uninstall.sh
\`\`\`

## Default daemon.json

The package ships with a minimal default configuration:

- \`log-driver\`: \`json-file\`
- \`log-opts.max-size\`: \`100m\`
- \`log-opts.max-file\`: \`3\`
- \`live-restore\`: \`true\`
- \`data-root\`: \`/var/lib/docker\`

## Notes

1. Run all scripts with \`root\` or \`sudo\`.
2. \`install.sh\` and \`upgrade.sh\` back up existing Docker binaries and config files before replacing them.
3. \`upgrade.sh\` keeps the existing \`/etc/docker/daemon.json\` when present.
4. \`migrate-data-root.sh\` restores the previous \`daemon.json\` automatically if migration fails.
5. \`uninstall.sh\` does not delete Docker data directories.
README_EOF

    sed_inplace "s|__DOCKER_VERSION__|${safe_version}|g" "${output_dir}/README.md"
    sed_inplace "s|__ARCH__|${safe_arch}|g"                "${output_dir}/README.md"
    sed_inplace "s|__COMPOSE_VERSION__|${compose_display}|g" "${output_dir}/README.md"
}

# ====================================================================
# MAIN
# ====================================================================

echo "============================================"
echo " Docker 离线安装包构建工具"
echo "============================================"
echo ""

# 检测 sed 风格
sed_style=$(detect_sed)

# 检查磁盘空间
check_disk_space

# ---- 确定版本号 ----
if [ -n "$arg_version" ]; then
    selected_version="$arg_version"
    validate_version "$selected_version" || exit 1
else
    # 交互式选择
    echo "[信息] 扫描已有 Docker tgz 包..."
    mapfile -t known_versions < <(scan_known_versions) 2>/dev/null || true

    # 如果 mapfile 不可用（旧版 bash），用 while 读
    if [ ${#known_versions[@]} -eq 0 ]; then
        while IFS= read -r v; do
            [ -n "$v" ] && known_versions+=("$v")
        done < <(scan_known_versions)
    fi

    echo ""
    echo "可选 Docker 版本:"
    local i=1
    for v in "${known_versions[@]}"; do
        printf "  %d) %s\n" "$i" "docker-${v}"
        ((i++))
    done
    echo "  c) 自定义版本（手动输入）"
    echo "  s) 跳过（仅指定架构和目标环境）"
    echo ""

    if [ "$non_interactive" = "1" ]; then
        echo "[错误] 非交互模式需要 --version 参数"
        exit 1
    fi

    read -r -p "请选择版本号 [输入数字 / c / s]: " choice

    case "$choice" in
        c|C)
            read -r -p "请输入自定义 Docker 版本号（如 29.6.1）: " selected_version
            validate_version "$selected_version" || exit 1
            ;;
        s|S)
            # 跳过版本选择，直接构建指定架构的空壳
            selected_version="custom"
            read -r -p "请输入自定义版本号: " selected_version
            validate_version "$selected_version" || exit 1
            ;;
        *)
            if [[ "$choice" =~ ^[0-9]+$ ]]; then
                local idx=$((choice - 1))
                if [ -z "${known_versions[$idx]:-}" ]; then
                    echo "[错误] 无效的选择: $choice"
                    exit 1
                fi
                selected_version="${known_versions[$idx]}"
            else
                echo "[错误] 无效的选择: $choice"
                exit 1
            fi
            ;;
    esac
fi

echo ""
echo "============================================"
echo " 目标版本: Docker ${selected_version}"
echo " 目标架构: ${target_arch}"
if [ "$use_china_mirror" = "1" ]; then
    echo " 镜像模式: 国内加速"
fi
echo "============================================"
echo ""

# ---- 国内镜像处理 ----
if [ "$use_china_mirror" = "1" ]; then
    # Compose: 使用 ghproxy.com
    compose_download_url="https://ghproxy.com/https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${target_arch}"

    # Docker tgz: 无公共镜像，给出提示
    if [ "$docker_download_base" = "https://download.docker.com/linux/static/stable/${target_arch}" ]; then
        echo "[注意] Docker 静态二进制包在中国大陆没有已知公共镜像。"
        echo "       将直接从 download.docker.com 下载，可能较慢。"
        echo "       建议: 设置 HTTP 代理 (export https_proxy=your-proxy:port)"
        echo "       或:    设置 DOCKER_DOWNLOAD_BASE 指向内部镜像服务器"
        echo ""
    fi
fi

# ---- 输出目录 ----
output_dir="${script_dir}/offline-docker-${selected_version}"

if [ -d "$output_dir" ]; then
    if [ "$non_interactive" = "1" ]; then
        echo "[信息] 目录已存在，非交互模式跳过覆盖。"
        echo "      手动删除后重试: rm -rf ${output_dir}"
        exit 1
    fi
    read -r -p "目录 ${output_dir} 已存在，是否覆盖？[y/N] " overwrite
    case $overwrite in
        [yY][eE][sS]|[yY]) rm -rf "$output_dir" ;;
        *) echo "已取消。"; exit 0 ;;
    esac
fi

mkdir -p "${output_dir}/config"
mkdir -p "${output_dir}/packages"

# ---- 下载 ----
target_tgz="docker-${selected_version}.tgz"
tgz_path="${output_dir}/packages/${target_tgz}"
download_docker_tgz "$target_tgz" "$tgz_path"

compose_path="${output_dir}/packages/docker-compose-linux"

if [ "$skip_compose" = "1" ]; then
    compose_version="(跳过)"
    echo "[2/4] 跳过 Docker Compose 下载（--skip-compose）"
    echo ""
elif [ -n "$arg_compose_file" ]; then
    echo "[2/4] 使用本地 Docker Compose 文件..."
    if [ ! -f "$arg_compose_file" ]; then
        echo "[错误] 指定的文件不存在: ${arg_compose_file}"
        exit 1
    fi
    cp -v "$arg_compose_file" "$compose_path"
    chmod 755 "$compose_path"

    # 尝试从文件名或二进制提取版本
    compose_version=$(file "$compose_path" 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1) || true
    if [ -z "$compose_version" ]; then
        compose_version="(本地文件，版本未知)"
    fi
    echo "      文件: ${arg_compose_file}"
    echo "      ✓ 已复制 ($(du -h "$compose_path" 2>/dev/null | awk '{print $1}'))"
    echo ""
else
    download_compose "$compose_path"
fi

# ---- 生成文件 ----
write_config_files
echo "[4/4] 生成安装/卸载脚本..."
write_install_sh
write_upgrade_sh
write_migrate_data_root_sh_v2
write_uninstall_sh
write_readme_v2
echo "      ✓ install.sh"
echo "      ✓ upgrade.sh"
echo "      ✓ uninstall.sh"
echo "      ✓ README.md"
echo ""

# ---- 解除清理陷阱 ----
trap - INT TERM

# ---- 最终输出 ----
echo "============================================"
echo " 构建完成！"
echo "============================================"
echo ""
echo " 输出目录: ${output_dir}"
echo " 总大小:   $(du -sh "$output_dir" 2>/dev/null | awk '{print $1}')"
echo ""
echo " 文件列表:"
find "$output_dir" -type f | sort | while read -r f; do
    rel="${f#${script_dir}/}"
    echo "   ${rel}"
done
echo ""
echo " 使用方法:"
echo "   1. 将 offline-docker-${selected_version}/ 目录拷贝到目标机器"
echo "   2. cd offline-docker-${selected_version}"
echo "   3. sudo bash install.sh"
echo ""
