#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX_DIR="$(mktemp -d)"
trap 'rm -rf "$SANDBOX_DIR"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

test_safe_config_parser() {
    local config_file="$SANDBOX_DIR/vps_config.conf"
    (
        cd "$ROOT_DIR"
        source lib/core.sh
        source lib/common.sh
        LOG_FILE="$SANDBOX_DIR/config.log"
        AUDIT_LOG="$SANDBOX_DIR/config-audit.log"
        printf '%s\n' \
            'USERNAME=deploy user' \
            'SSH_PUBKEY=ssh-ed25519 AAAA user@host' \
            'MALICIOUS=$(touch should-not-exist)' > "$config_file"
        chmod 600 "$config_file"
        load_config "$config_file"
        [ "$USERNAME" = 'deploy user' ]
        [ "$SSH_PUBKEY" = 'ssh-ed25519 AAAA user@host' ]
        [ ! -e "$SANDBOX_DIR/should-not-exist" ]
    ) || fail "safe configuration parser"
}

test_access_guard() {
    local isolated_repo="$SANDBOX_DIR/access-guard"
    cp -a "$ROOT_DIR" "$isolated_repo"
    rm -f "$isolated_repo/config/vps_config.conf" "$isolated_repo/config/.state"
    if VPS_SETUP_USERNAME="vps-init-no-credential" \
        VPS_SETUP_PASSWORD_AUTH=no \
        VPS_SETUP_SSH_PUBKEY_AUTHENTICATION=yes \
        "$isolated_repo/vps_setup.sh" -n -a -f --modules 04_user,05_ssh >"$SANDBOX_DIR/access.out" 2>&1; then
        fail "access guard accepted an unusable SSH credential"
    fi
    grep -Fq 'Public-key authentication is enabled, but no authorized SSH public key is available' "$SANDBOX_DIR/access.out" || \
        fail "access guard error message"
    if grep -Fq 'Starting SSH hardening' "$SANDBOX_DIR/access.out"; then
        fail "SSH hardening started without a usable credential"
    fi
}

test_module_source_guard() {
    (
        cd "$ROOT_DIR"
        source lib/core.sh
        source modules/08_docker.sh
        declare -F docker_main >/dev/null
    ) || fail "module source guard"
}

test_unsafe_install_dir_guard() {
    local install_input="$SANDBOX_DIR/install-stdin.sh"
    {
        printf '%s\n' 'curl() { return 99; }'
        tail -n +2 "$ROOT_DIR/install.sh"
    } > "$install_input"
    if sudo bash "$install_input" --install-dir /etc --update-only >"$SANDBOX_DIR/install-dir.out" 2>&1; then
        fail "installer accepted /etc as its installation directory"
    fi
    grep -Fqx 'Refusing unsafe install directory: /etc' "$SANDBOX_DIR/install-dir.out" || \
        fail "unsafe install directory rejection"
}

test_safe_config_parser
test_access_guard
test_module_source_guard
test_unsafe_install_dir_guard
printf 'Regression checks passed.\n'