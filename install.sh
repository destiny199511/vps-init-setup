#!/bin/bash
set -euo pipefail

usage() {
    cat <<EOF
VPS 一键装机安装脚本

用法: sudo bash install.sh [选项]

选项:
  --install-dir DIR   目标安装目录 (default: /opt/vps-init-setup)
    --ref COMMIT        40 位不可变 Git commit（远程安装必填）
    --sha256 SHA256     对应归档的 SHA-256（远程安装必填）
    --repo-url URL      指定 GitHub HTTPS 或 SSH 仓库 URL
    --update-only       仅更新源码，不启动初始化向导
  --help, -h          显示此帮助信息

其他参数将直接传递给 vps_setup.sh
EOF
}

INSTALL_DIR="${VPS_INIT_SETUP_INSTALL_DIR:-/opt/vps-init-setup}"
REF="${VPS_INIT_SETUP_REF:-}"
REPO_URL="${VPS_INIT_SETUP_REPO_URL:-https://github.com/destiny199511/vps-init-setup.git}"
EXPECTED_SHA256="${VPS_INIT_SETUP_SHA256:-}"
UPDATE_ONLY=false
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
        --sha256)
            EXPECTED_SHA256="$2"
            shift 2
            ;;
        --update-only)
            UPDATE_ONLY=true
            shift
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
    if [[ ! "$REF" =~ ^[0-9a-fA-F]{40}$ ]]; then
        echo "错误: 远程安装必须通过 --ref 指定 40 位不可变 Git commit。" >&2
        exit 1
    fi
    if [[ ! "$EXPECTED_SHA256" =~ ^[0-9a-fA-F]{64}$ ]]; then
        echo "错误: 远程安装必须通过 --sha256 提供已独立发布的归档校验和。" >&2
        exit 1
    fi

    if [[ "$REPO_URL" =~ ^https://github\.com/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)(\.git)?$ ]] || \
       [[ "$REPO_URL" =~ ^git@github\.com:([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)(\.git)?$ ]]; then
        repo="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    else
        echo "错误: 远程安装只接受规范的 GitHub HTTPS 或 SSH 仓库 URL。" >&2
        exit 1
    fi

    echo "正在下载 VPS 初始化脚本 (${REF})..."
    mkdir -p "$INSTALL_DIR"

    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "$tmp_dir"' EXIT

    archive_url="https://github.com/${repo}/archive/${REF}.tar.gz"
    if ! curl --connect-timeout 10 --max-time 120 --retry 2 --retry-all-errors -fsSL \
        "$archive_url" -o "$tmp_dir/source.tar.gz"; then
        echo "错误: 下载源码包失败，请检查网络连接或仓库地址。" >&2
        exit 1
    fi

    echo "正在验证源码归档 SHA-256 完整性..."
    if ! printf '%s  %s\n' "$EXPECTED_SHA256" "$tmp_dir/source.tar.gz" | sha256sum -c - >/dev/null 2>&1; then
        echo "FATAL: 源码归档 SHA-256 校验失败！" >&2
        exit 1
    fi
    echo "SHA-256 校验通过。"

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

if [ "$UPDATE_ONLY" = true ]; then
    echo "代码已更新至 ${INSTALL_DIR}，--update-only 模式结束。"
    exit 0
fi

echo "安装完成，正在启动初始化向导..."
if [ -r /dev/tty ]; then
    exec bash ./vps_setup.sh "${PASSTHROUGH_ARGS[@]}" </dev/tty >/dev/tty 2>&1
else
    exec bash ./vps_setup.sh "${PASSTHROUGH_ARGS[@]}"
fi
