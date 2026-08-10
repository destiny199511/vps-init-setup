#!/bin/bash
set -euo pipefail

usage() {
    cat <<EOF
Usage: sudo bash install.sh [options]

Options:
  --repo-url URL      GitHub repository URL (default: ${REPO_URL})
  --ref REF           GitHub release tag or branch to install (default: ${REF})
  --install-dir DIR   Target directory (default: ${INSTALL_DIR})
    --update-only       Update files without starting the setup wizard
  --help              Show this help

Environment variables:
  VPS_INIT_SETUP_REPO_URL
  VPS_INIT_SETUP_REF
  VPS_INIT_SETUP_INSTALL_DIR
EOF
}

SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"
if [ -n "$SCRIPT_SOURCE" ] && [ -f "$SCRIPT_SOURCE" ]; then
    SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" >/dev/null 2>&1 && pwd)"
else
    SCRIPT_DIR=""
fi
REPO_URL="${VPS_INIT_SETUP_REPO_URL:-https://github.com/destiny199511/vps-init-setup.git}"
INSTALL_DIR="${VPS_INIT_SETUP_INSTALL_DIR:-/opt/vps-init-setup}"
REF="${VPS_INIT_SETUP_REF:-$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo "latest") }"
RUN_SETUP=true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo-url)
            REPO_URL="$2"
            shift 2
            ;;
        --ref)
            REF="$2"
            shift 2
            ;;
        --install-dir)
            INSTALL_DIR="$2"
            shift 2
            ;;
        --update-only)
            RUN_SETUP=false
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
done

REF="${REF# }"
REF="${REF% }"

if [ "$(id -u)" -ne 0 ]; then
    echo "This installer must be run as root or with sudo."
    exit 1
fi

install_package() {
    local pkg="$1"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update >/dev/null 2>&1
        apt-get install -y "$pkg" >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "$pkg" >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "$pkg" >/dev/null 2>&1
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache "$pkg" >/dev/null 2>&1
    else
        echo "Unsupported OS: could not install $pkg automatically."
        exit 1
    fi
}

for tool in curl tar; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "$tool not found. Installing $tool..."
        install_package "$tool"
    fi
done

normalize_repo() {
    local repo="$1"
    repo="${repo#git@github.com:}"
    repo="${repo#https://github.com/}"
    repo="${repo#http://github.com/}"
    repo="${repo%.git}"
    echo "$repo"
}

resolve_release_tag() {
    local repo="$1"
    local requested_ref="$2"
    local api_url

    if [ "$requested_ref" = "latest" ] || [ -z "$requested_ref" ]; then
        api_url="https://api.github.com/repos/${repo}/releases/latest"
        local release_json
        release_json="$(curl -fsSL -H 'Accept: application/vnd.github+json' -H 'User-Agent: vps-init-setup-installer' "$api_url" 2>/dev/null || true)"
        local tag_name
        tag_name="$(printf '%s\n' "$release_json" | sed -n 's/.*"tag_name": *"\([^\"]*\)".*/\1/p' | head -n 1)"
        if [ -n "$tag_name" ]; then
            printf '%s\n' "$tag_name"
        else
            printf 'main\n'
        fi
    else
        printf '%s\n' "$requested_ref"
    fi
}

resolve_download_url() {
    local repo="$1"
    local release_tag="$2"
    local api_url
    local release_json
    local asset_url

    if [ "$release_tag" = "latest" ] || [ -z "$release_tag" ]; then
        api_url="https://api.github.com/repos/${repo}/releases/latest"
        release_json="$(curl -fsSL -H 'Accept: application/vnd.github+json' -H 'User-Agent: vps-init-setup-installer' "$api_url")"
        release_tag="$(printf '%s\n' "$release_json" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)"
    fi

    if [ -n "$release_tag" ] && [ "$release_tag" != "main" ] && [ "$release_tag" != "master" ]; then
        api_url="https://api.github.com/repos/${repo}/releases/tags/${release_tag}"
        release_json="$(curl -fsSL -H 'Accept: application/vnd.github+json' -H 'User-Agent: vps-init-setup-installer' "$api_url" 2>/dev/null || true)"
        asset_url="$(printf '%s\n' "$release_json" | grep -o '"browser_download_url": "[^"]*"' | sed 's/.*"\([^\"]*\)"/\1/' | grep -E 'vps-init-setup.*\.(tar\.gz|tgz)$' | head -n 1 || true)"
        if [ -n "$asset_url" ]; then
            printf '%s\n' "$asset_url"
            return 0
        fi
    fi

    if [ "$release_tag" = "main" ] || [ "$release_tag" = "master" ] || [ -z "$release_tag" ]; then
        printf 'https://github.com/%s/archive/refs/heads/%s.tar.gz\n' "$repo" "$release_tag"
    else
        printf 'https://github.com/%s/archive/refs/tags/%s.tar.gz\n' "$repo" "$release_tag"
    fi
}

if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/vps_setup.sh" ]; then
    echo "Using local repository at $SCRIPT_DIR"
    INSTALL_DIR="$SCRIPT_DIR"
else
    repo_path="$(normalize_repo "$REPO_URL")"
    release_tag="$(resolve_release_tag "$repo_path" "$REF")"
    archive_url="$(resolve_download_url "$repo_path" "$release_tag")"

    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "$tmp_dir"' EXIT

    echo "Installing release ${release_tag} from ${archive_url}"
    curl -fsSL "$archive_url" -o "$tmp_dir/source.tar.gz"
    tar -xzf "$tmp_dir/source.tar.gz" -C "$tmp_dir"

    extracted_dir="$(find "$tmp_dir" -maxdepth 1 -mindepth 1 -type d | head -n 1)"
    if [ -z "$extracted_dir" ]; then
        echo "Failed to extract the downloaded archive."
        exit 1
    fi

    preserved_dir="$(mktemp -d)"
    for data_dir in config logs backups; do
        if [ -d "$INSTALL_DIR/$data_dir" ]; then
            mkdir -p "$preserved_dir/$data_dir"
            cp -a "$INSTALL_DIR/$data_dir/." "$preserved_dir/$data_dir/"
        fi
    done

    rm -rf "$INSTALL_DIR"
    mkdir -p "$(dirname "$INSTALL_DIR")"
    cp -R "$extracted_dir" "$INSTALL_DIR"

    for data_dir in config logs backups; do
        if [ -d "$preserved_dir/$data_dir" ]; then
            mkdir -p "$INSTALL_DIR/$data_dir"
            cp -a "$preserved_dir/$data_dir/." "$INSTALL_DIR/$data_dir/"
        fi
    done
    rm -rf "$preserved_dir"
fi

cd "$INSTALL_DIR"
chmod +x vps_setup.sh

if [ "$RUN_SETUP" = "false" ]; then
    echo "Update complete. Setup wizard was not started."
    exit 0
fi

echo "Starting VPS setup..."
echo "Install directory: $INSTALL_DIR"
# 默认进入交互模式，只有在需要无人值守安装时才传递 -n
if [ -r /dev/tty ]; then
    exec bash ./vps_setup.sh </dev/tty >/dev/tty 2>&1
else
    exec bash ./vps_setup.sh
fi
