#!/bin/bash
set -euo pipefail

usage() {
    cat <<EOF
Usage: sudo bash install.sh [options]

Options:
  --repo-url URL      GitHub repository URL (default: ${REPO_URL})
  --ref REF           GitHub release tag or branch to install (default: ${REF})
    --install-dir DIR   Target directory (default: ${INSTALL_DIR})
    --sha256 SHA256      Expected archive SHA-256 (recommended for production)
    --update-only        Update files without starting the setup wizard
  --help              Show this help

Environment variables:
  VPS_INIT_SETUP_REPO_URL
  VPS_INIT_SETUP_REF
  VPS_INIT_SETUP_INSTALL_DIR
    VPS_INIT_SETUP_SHA256
EOF
}

INSTALL_MARKER=".vps-init-setup-managed"

SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"
if [ -n "$SCRIPT_SOURCE" ] && [ "$SCRIPT_SOURCE" != "bash" ] && [ "$SCRIPT_SOURCE" != "-" ] && [ -f "$SCRIPT_SOURCE" ]; then
    SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" >/dev/null 2>&1 && pwd)"
else
    SCRIPT_DIR=""
fi
REPO_URL="${VPS_INIT_SETUP_REPO_URL:-https://github.com/destiny199511/vps-init-setup.git}"
INSTALL_DIR="${VPS_INIT_SETUP_INSTALL_DIR:-/opt/vps-init-setup}"
REF="${VPS_INIT_SETUP_REF:-$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo "latest") }"
EXPECTED_SHA256="${VPS_INIT_SETUP_SHA256:-}"
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
        --sha256)
            EXPECTED_SHA256="$2"
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

if [ -n "$EXPECTED_SHA256" ] && [[ ! "$EXPECTED_SHA256" =~ ^[a-fA-F0-9]{64}$ ]]; then
    echo "Expected SHA-256 must contain exactly 64 hexadecimal characters."
    exit 1
fi

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

validate_install_dir() {
    local install_parent install_owner install_mode

    case "$INSTALL_DIR" in
        /*) ;;
        *)
            echo "Install directory must be an absolute path: $INSTALL_DIR"
            exit 1
            ;;
    esac
    INSTALL_DIR="${INSTALL_DIR%/}"
    [ -n "$INSTALL_DIR" ] || INSTALL_DIR="/"

    if [[ "$INSTALL_DIR" == *$'\n'* || "$INSTALL_DIR" == *$'\r'* || "$INSTALL_DIR" == *'/./'* || "$INSTALL_DIR" == */. || "$INSTALL_DIR" == *'/../'* || "$INSTALL_DIR" == */.. ]]; then
        echo "Install directory must not contain relative path components or control characters: $INSTALL_DIR"
        exit 1
    fi

    case "$INSTALL_DIR" in
        /opt/*|/srv/*|/usr/local/src/*) ;;
        *)
            echo "Refusing unsafe install directory: $INSTALL_DIR"
            echo "Choose a dedicated directory below /opt, /srv, or /usr/local/src."
            exit 1
            ;;
    esac
    if [ -L "$INSTALL_DIR" ]; then
        echo "Refusing symbolic-link install directory: $INSTALL_DIR"
        exit 1
    fi
    if [ -e "$INSTALL_DIR" ] && [ ! -d "$INSTALL_DIR" ]; then
        echo "Install path exists but is not a directory: $INSTALL_DIR"
        exit 1
    fi

    install_parent="$(dirname "$INSTALL_DIR")"
    if [ ! -d "$install_parent" ]; then
        mkdir -p "$install_parent"
    fi
    if [ -L "$install_parent" ]; then
        echo "Refusing install directory with symbolic-link parent: $install_parent"
        exit 1
    fi

    if [ -d "$INSTALL_DIR" ]; then
        install_owner="$(stat -c '%u' "$INSTALL_DIR" 2>/dev/null || true)"
        install_mode="$(stat -c '%a' "$INSTALL_DIR" 2>/dev/null || true)"
        if [ "$install_owner" != "0" ] || [ -z "$install_mode" ] || (( (8#$install_mode) & 022 )); then
            echo "Install directory must be owned by root and not group/world writable: $INSTALL_DIR"
            exit 1
        fi

        if [ -f "$INSTALL_DIR/$INSTALL_MARKER" ]; then
            return 0
        fi
        if [ -f "$INSTALL_DIR/vps_setup.sh" ] && [ -d "$INSTALL_DIR/lib" ] && [ -d "$INSTALL_DIR/modules" ]; then
            echo "Adopting a secure legacy installation at $INSTALL_DIR"
            return 0
        fi
        if [ -n "$(find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
            echo "Refusing non-empty directory that is not a vps-init-setup installation: $INSTALL_DIR"
            exit 1
        fi
    fi
}

validate_release_tree() {
    local release_dir required_file

    release_dir="$1"
    if find "$release_dir" -xdev -type l -print -quit | grep -q .; then
        echo "Downloaded release contains symbolic links; refusing to install it."
        exit 1
    fi
    for required_file in vps_setup.sh lib/core.sh lib/common.sh modules/{00_preflight,01_hostname,02_locale_timezone,03_dns,04_user,05_ssh,06_firewall,07_fail2ban,08_docker,09_network,10_backup,11_monitoring,12_security,13_cleanup}.sh; do
        if [ ! -f "$release_dir/$required_file" ]; then
            echo "Downloaded release is incomplete: missing $required_file"
            exit 1
        fi
    done
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

verify_release_checksum() {
    local archive_file="$1"
    local archive_url="$2"
    local checksum_url checksum_file expected_checksum actual_checksum

    if [ -n "$EXPECTED_SHA256" ]; then
        expected_checksum="$EXPECTED_SHA256"
    else
        case "$archive_url" in
            */archive/refs/heads/*)
                echo "Warning: installing an unpinned development branch archive. Use a release tag and --sha256 for production."
                return 0
                ;;
        esac
        checksum_url="${archive_url}.sha256"
        checksum_file="${archive_file}.sha256"
        if ! curl -fsSL "$checksum_url" -o "$checksum_file"; then
            echo "Release checksum is unavailable: $checksum_url"
            exit 1
        fi
        expected_checksum="$(awk 'NF {print $1; exit}' "$checksum_file")"
    fi
    actual_checksum="$(sha256sum "$archive_file" | awk '{print $1}')"
    if [[ ! "$expected_checksum" =~ ^[a-fA-F0-9]{64}$ ]] || [ "$expected_checksum" != "$actual_checksum" ]; then
        echo "Release checksum verification failed."
        exit 1
    fi
    echo "Release checksum verified."
}

if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/vps_setup.sh" ]; then
    echo "Using local repository at $SCRIPT_DIR"
    INSTALL_DIR="$SCRIPT_DIR"
else
    validate_install_dir
    repo_path="$(normalize_repo "$REPO_URL")"
    release_tag="$(resolve_release_tag "$repo_path" "$REF")"
    archive_url="$(resolve_download_url "$repo_path" "$release_tag")"

    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "$tmp_dir"' EXIT

    echo "Installing release ${release_tag} from ${archive_url}"
    curl -fsSL "$archive_url" -o "$tmp_dir/source.tar.gz"
    verify_release_checksum "$tmp_dir/source.tar.gz" "$archive_url"
    if tar -tzf "$tmp_dir/source.tar.gz" | grep -qE '(^/|(^|/)\.\.(/|$))'; then
        echo "Downloaded release contains unsafe archive paths; refusing to extract it."
        exit 1
    fi
    tar -xzf "$tmp_dir/source.tar.gz" -C "$tmp_dir"

    extracted_dir="$(find "$tmp_dir" -maxdepth 1 -mindepth 1 -type d | head -n 1)"
    if [ -z "$extracted_dir" ]; then
        echo "Failed to extract the downloaded archive."
        exit 1
    fi

    validate_release_tree "$extracted_dir"

    # Runtime state belongs to the target host, never to a source archive.
    rm -rf "$extracted_dir/config" "$extracted_dir/logs" "$extracted_dir/backups"

    # Keep INSTALL_DIR itself so callers currently in it retain a valid cwd.
    mkdir -p "$INSTALL_DIR"
    find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 \
        ! -name config ! -name logs ! -name backups ! -name "$INSTALL_MARKER" \
        -exec rm -rf -- {} +
    cp -a --no-preserve=ownership "$extracted_dir/." "$INSTALL_DIR/"
    chown root:root "$INSTALL_DIR"
fi

cd "$INSTALL_DIR"
chmod +x vps_setup.sh

for required_file in vps_setup.sh lib/core.sh lib/common.sh modules/{00_preflight,01_hostname,02_locale_timezone,03_dns,04_user,05_ssh,06_firewall,07_fail2ban,08_docker,09_network,10_backup,11_monitoring,12_security,13_cleanup}.sh; do
    if [ ! -f "$INSTALL_DIR/$required_file" ]; then
        echo "Installation is incomplete: missing $INSTALL_DIR/$required_file"
        exit 1
    fi
done

if [ "$SCRIPT_DIR" != "$INSTALL_DIR" ]; then
    printf 'managed-by=vps-init-setup\n' > "$INSTALL_DIR/$INSTALL_MARKER"
    chmod 600 "$INSTALL_DIR/$INSTALL_MARKER"
fi

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
