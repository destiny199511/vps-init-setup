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

test_tui_engine_load() {
    (
        cd "$ROOT_DIR"
        source lib/core.sh
        source lib/common.sh
        source lib/tui.sh
        declare -F tui_menu_select >/dev/null
        declare -F tui_yesno_box >/dev/null
        declare -F tui_card_input >/dev/null
    ) || fail "TUI engine failed to load or declare functions"
}

test_tui_noninteractive_fallback() {
    (
        cd "$ROOT_DIR"
        source lib/core.sh
        source lib/common.sh
        source lib/tui.sh
        NON_INTERACTIVE=true
        AUTO_YES=false
        local choice input_value
        tui_menu_select choice "Test" "Test prompt" 2 "first" "second"
        [ "$choice" = "second" ]
        tui_card_input input_value "Test" "Test prompt" "default-value"
        [ "$input_value" = "default-value" ]
    ) || fail "TUI non-interactive fallback"
}

test_tui_eof_cancellation() {
    (
        cd "$ROOT_DIR"
        source lib/core.sh
        source lib/common.sh
        source lib/tui.sh
        NON_INTERACTIVE=false
        AUTO_YES=false
        local value
        if tui_menu_select value "Test" "Test prompt" 1 "first" "second" </dev/null >/dev/null; then
            return 1
        else
            [ "$?" -eq 2 ]
        fi
        if tui_yesno_box "Test" "Test prompt" "y" </dev/null >/dev/null; then
            return 1
        else
            [ "$?" -eq 2 ]
        fi
        if tui_card_input value "Test" "Test prompt" "default-value" "" false </dev/null >/dev/null; then
            return 1
        else
            [ "$?" -eq 2 ]
        fi
    ) || fail "TUI EOF cancellation"
}

test_apt_lock_wait_guard() {
    (
        cd "$ROOT_DIR"
        source lib/core.sh
        PKG_MGR="apt"
        APT_LOCK_WAIT=1
        declare -F wait_for_apt_lock >/dev/null
        declare -F _apt_lock_holders >/dev/null
        wait_for_apt_lock
    ) || fail "apt lock wait guard"
}

test_apply_config_defaults_completeness() {
    (
        cd "$ROOT_DIR"
        source lib/core.sh
        source lib/common.sh
        apply_config_defaults
        for var in $(get_config_var_names); do
            case "$var" in
                USER_PASSWORD|SSH_PUBKEY|ALLOWED_PORTS|DOCKER_INSECURE_REGISTRIES|DOCKER_REGISTRY_MIRRORS|FAIL2BAN_IGNOREIP|BACKUP_GPG_RECIPIENT|SWAP_SIZE|USER_FULLNAME)
                    # These can be empty by default
                    ;;
                *)
                    [ -n "${!var:-}" ] || {
                        echo "Config var $var is empty after apply_config_defaults"
                        return 1
                    }
                    ;;
            esac
        done
    ) || fail "apply_config_defaults completeness"
}

test_i18n_translation_and_fallbacks() {
    (
        cd "$ROOT_DIR"
        source lib/core.sh
        source lib/common.sh
        source lib/i18n.sh
        set_ui_language en
        [ "$(t '主菜单 (Main Menu)')" = "Main Menu" ]
        set_ui_language ja
        [ "$(t '主菜单 (Main Menu)')" = "メインメニュー" ]
        set_ui_language es
        [ "$(t '主菜单 (Main Menu)')" = "Menú Principal" ]
        set_ui_language zh
        [ "$(t '主菜单 (Main Menu)')" = "主菜单 (Main Menu)" ]
    ) || fail "i18n translation and fallbacks"
}

test_docker_install_flag_skip() {
    (
        cd "$ROOT_DIR"
        source lib/core.sh
        source lib/common.sh
        source modules/08_docker.sh
        INSTALL_DOCKER="false"
        INSTALL_NPM="false"
        docker_main
    ) || fail "docker module should skip cleanly when INSTALL_DOCKER=false"
}

test_fail2ban_install_flag_skip() {
    (
        cd "$ROOT_DIR"
        source lib/core.sh
        source lib/common.sh
        source modules/07_fail2ban.sh
        INSTALL_FAIL2BAN="false"
        fail2ban_main
    ) || fail "fail2ban module should skip cleanly when INSTALL_FAIL2BAN=false"
}

test_network_security_sysctl_generation() {
    (
        cd "$ROOT_DIR"
        source lib/core.sh
        source lib/common.sh
        source modules/09_network.sh
        # Verify network_info and prerequisites
        network_info >/dev/null
        network_prerequisites
    ) || fail "network security sysctl module check"
}

test_safe_config_parser
test_access_guard
test_module_source_guard
test_tui_engine_load
test_tui_noninteractive_fallback
test_tui_eof_cancellation
test_apt_lock_wait_guard
test_apply_config_defaults_completeness
test_i18n_translation_and_fallbacks
test_docker_install_flag_skip
test_fail2ban_install_flag_skip
test_network_security_sysctl_generation
test_unsafe_install_dir_guard
printf 'Regression checks passed.\n'