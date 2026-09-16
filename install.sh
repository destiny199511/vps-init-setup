#!/bin/bash
set -euo pipefail

usage() {
    cat <<EOF
VPS 一键装机安装脚本

用法: sudo bash install.sh [选项]

选项:
  --install-dir DIR   目标安装目录 (default: /opt/vps-init-setup)
  --ref REF           安装的分支或标签 (default: main)
  --repo-url URL      指定代码仓库 URL
  --help, -h          显示此帮助信息

其他参数将直接传递给 vps_setup.sh
EOF
}

INSTALL_DIR="${VPS_INIT_SETUP_INSTALL_DIR:-/opt/vps-init-setup}"
REF="${VPS_INIT_SETUP_REF:-main}"
REPO_URL="${VPS_INIT_SETUP_REPO_URL:-https://github.com/destiny199511/vps-init-setup.git}"
PASSTHROUGH_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --install-dir)
            INSTALL_DIR="$2"
            shift 2
            ;;
        --ref)
            REF="$2"
            shift 2
            ;;
        --repo-url)
            REPO_URL="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            PASSTHROUGH_ARGS+=("$1")
            shift
            ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    echo "错误: 请使用 root 权限或 sudo 运行此安装脚本。" >&2
    exit 1
fi

if [ -z "$INSTALL_DIR" ] || [ "$INSTALL_DIR" = "/" ] || [ "$INSTALL_DIR" = "/etc" ] || [ "$INSTALL_DIR" = "/bin" ] || [ "$INSTALL_DIR" = "/sbin" ] || [ "$INSTALL_DIR" = "/usr" ] || [ "$INSTALL_DIR" = "/var" ]; then
    echo "Refusing unsafe install directory: $INSTALL_DIR" >&2
    exit 1
fi

install_package() {
    local pkg="$1"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y >/dev/null 2>&1 && apt-get install -y "$pkg" >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "$pkg" >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "$pkg" >/dev/null 2>&1
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache "$pkg" >/dev/null 2>&1
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm "$pkg" >/dev/null 2>&1
    elif command -v zypper >/dev/null 2>&1; then
        zypper install -y "$pkg" >/dev/null 2>&1
    fi
}

for tool in curl tar; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "正在安装基础依赖 $tool..."
        install_package "$tool"
    fi
done

SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"
if [ -n "$SCRIPT_SOURCE" ] && [ "$SCRIPT_SOURCE" != "bash" ] && [ "$SCRIPT_SOURCE" != "-" ] && [ -f "$SCRIPT_SOURCE" ]; then
    SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" >/dev/null 2>&1 && pwd)"
else
    SCRIPT_DIR=""
fi

if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/vps_setup.sh" ]; then
    INSTALL_DIR="$SCRIPT_DIR"
else
    echo "正在下载 VPS 初始化脚本 (${REF})..."
    mkdir -p "$INSTALL_DIR"

    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "$tmp_dir"' EXIT

    repo="${REPO_URL#git@github.com:}"
    repo="${repo#https://github.com/}"
    repo="${repo#http://github.com/}"
    repo="${repo%.git}"

    archive_url="https://github.com/${repo}/archive/refs/heads/${REF}.tar.gz"
    if ! curl -fsSL "$archive_url" -o "$tmp_dir/source.tar.gz" 2>/dev/null; then
        archive_url="https://github.com/${repo}/archive/refs/tags/${REF}.tar.gz"
        if ! curl -fsSL "$archive_url" -o "$tmp_dir/source.tar.gz"; then
            echo "错误: 下载源码包失败，请检查网络连接或仓库地址。" >&2
            exit 1
        fi
    fi

    echo "正在解压并安装到 ${INSTALL_DIR} ..."
    mkdir -p "$tmp_dir/extracted"
    tar -xzf "$tmp_dir/source.tar.gz" -C "$tmp_dir/extracted"

    extracted_dir="$(find "$tmp_dir/extracted" -maxdepth 2 -name "vps_setup.sh" -exec dirname {} \; | head -n 1)"
    if [ -z "$extracted_dir" ] || [ ! -f "$extracted_dir/vps_setup.sh" ]; then
        echo "错误: 源码包解压失败或缺少核心文件。" >&2
        exit 1
    fi

    # 保留用户现有配置与日志
    rm -rf "$extracted_dir/logs" "$extracted_dir/backups"
    if [ -f "$INSTALL_DIR/config/vps_config.conf" ]; then
        rm -rf "$extracted_dir/config"
    fi

    mkdir -p "$INSTALL_DIR"
    cp -a "$extracted_dir/." "$INSTALL_DIR/"
fi

cd "$INSTALL_DIR"
chmod +x vps_setup.sh lib/*.sh modules/*.sh 2>/dev/null || chmod +x vps_setup.sh

echo "安装完成，正在启动初始化向导..."
if [ -r /dev/tty ]; then
    exec bash ./vps_setup.sh "${PASSTHROUGH_ARGS[@]}" </dev/tty >/dev/tty 2>&1
else
    exec bash ./vps_setup.sh "${PASSTHROUGH_ARGS[@]}"
fi
