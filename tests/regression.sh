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
        SKIP_ROOT_CHECK=true \
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

test_install_default_ref() {
    local help_out
    help_out=$(bash "$ROOT_DIR/install.sh" --help)
    echo "$help_out" | grep -Fq '(default: main)' || \
        fail "install.sh should default to main branch"
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
        if tui_card_input value "Test" "Test prompt" "" "" true </dev/null >/dev/null; then
            return 1
        else
            [ "$?" -eq 2 ]
        fi
    ) || fail "TUI EOF cancellation"
}

test_tui_card_input_password_masking() {
    python3 - << 'EOF' || fail "TUI password masking failed"
import pty, os, time, sys

master, slave = pty.openpty()
pid = os.fork()
if pid == 0:
    os.close(master)
    os.dup2(slave, 0)
    os.dup2(slave, 1)
    os.dup2(slave, 2)
    os.close(slave)
    bash_code = """
        source lib/core.sh
        source lib/common.sh
        source lib/tui.sh
        pwd_val=""
        tui_card_input pwd_val "安全凭据" "请输入密码" "" "" true
        echo "RESULT:$pwd_val"
    """
    os.execlp('bash', 'bash', '-c', bash_code)
else:
    os.close(slave)
    time.sleep(0.1)
    # 输入 pass, 退格两次, 输入 word, 回车
    os.write(master, b"pass\x7f\x7fword\n")
    time.sleep(0.2)
    out = b""
    while True:
        try:
            chunk = os.read(master, 1024)
            if not chunk:
                break
            out += chunk
        except OSError:
            break
    os.close(master)
    _, status = os.waitpid(pid, 0)
    text = out.decode("utf-8", errors="replace")
    if "RESULT:paword" not in text:
        sys.exit(1)
    # 验证打字时包含星号掩码
    if "******" not in text:
        sys.exit(1)
EOF
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

test_i18n_variable_interpolation() {
    (
        cd "$ROOT_DIR"
        source lib/core.sh
        source lib/common.sh
        source lib/i18n.sh
        count=42
        [ "$(t '已恢复 ${count} 个文件')" = "已恢复 42 个文件" ]
        set_ui_language en
        [ "$(t '已恢复 ${count} 个文件')" = "Restored 42 files" ]
    ) || fail "i18n variable interpolation"
}

test_eval_elimination_in_user_module() {
    if grep -q 'eval.*\$username' "$ROOT_DIR/modules/04_user.sh"; then
        fail "eval still present in modules/04_user.sh"
    fi
}

test_root_guard() {
    local isolated_repo="$SANDBOX_DIR/root-guard"
    cp -a "$ROOT_DIR" "$isolated_repo"
    local output
    if output=$("$isolated_repo/vps_setup.sh" 2>&1); then
        fail "vps_setup.sh should fail when run as non-root"
    fi
    echo "$output" | grep -Fq "必须以 root 权限运行" || fail "root guard missing friendly error message"
}

test_rollback_cli_guard() {
    local isolated_repo="$SANDBOX_DIR/rollback-guard"
    cp -a "$ROOT_DIR" "$isolated_repo"
    local output
    output=$(SKIP_ROOT_CHECK=true "$isolated_repo/vps_setup.sh" -n -a --rollback 2>&1)
    echo "$output" | grep -Fq "无可回滚的文件" || fail "rollback without registry should report no files"
}

test_health_report_cli() {
    local isolated_repo="$SANDBOX_DIR/health-report-guard"
    cp -a "$ROOT_DIR" "$isolated_repo"
    local output
    output=$("$isolated_repo/vps_setup.sh" --health 2>&1)
    echo "$output" | grep -Fq "VPS 实际生效状态" || fail "--health missing live system state section"
    echo "$output" | grep -Fq "配置体检报告" || fail "--health missing health report section"
    echo "$output" | grep -Fq "配置检视指引" || fail "--health missing config inspection guidance"
}

test_view_config_cli() {
    local isolated_repo="$SANDBOX_DIR/view-config-guard"
    cp -a "$ROOT_DIR" "$isolated_repo"
    local output
    # Test --view all
    output=$("$isolated_repo/vps_setup.sh" --view 2>&1)
    echo "$output" | grep -Fq "用户与权限配置" || fail "--view all missing user section"
    echo "$output" | grep -Fq "SSH 服务与安全配置" || fail "--view all missing ssh section"
    echo "$output" | grep -Fq "防火墙与开放端口" || fail "--view all missing firewall section"
    echo "$output" | grep -Fq "Docker 容器环境配置" || fail "--view all missing docker section"
    echo "$output" | grep -Fq "系统备份任务配置" || fail "--view all missing backup section"
    echo "$output" | grep -Fq "系统监控与指标探针" || fail "--view all missing monitoring section"
    echo "$output" | grep -Fq "系统优化与内核调优" || fail "--view all missing optimization section"

    # Test single sections
    output=$("$isolated_repo/vps_setup.sh" --view ssh 2>&1)
    echo "$output" | grep -Fq "SSH 服务与安全配置" || fail "--view ssh failed"
    output=$("$isolated_repo/vps_setup.sh" --view docker 2>&1)
    echo "$output" | grep -Fq "Docker 容器环境配置" || fail "--view docker failed"
}

test_ssh_legacy_port_and_pubkey_configuration() {
    local isolated_repo="$SANDBOX_DIR/ssh-pubkey-guard"
    cp -a "$ROOT_DIR" "$isolated_repo"
    local config_file="$isolated_repo/config/vps_config.conf"

    # Test that SSH_KEEP_LEGACY_PORT=false is preserved and parsed properly
    (
        cd "$isolated_repo"
        source lib/core.sh
        source lib/common.sh
        printf '%s\n' \
            'SSH_PORT=24822' \
            'SSH_KEEP_LEGACY_PORT=false' \
            'PASSWORD_AUTH=no' \
            'SSH_PUBKEY_AUTHENTICATION=yes' \
            'SSH_PUBKEY=ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey user@workstation' > "$config_file"
        chmod 600 "$config_file"
        load_config "$config_file"
        [ "$SSH_PORT" = "24822" ]
        [ "$SSH_KEEP_LEGACY_PORT" = "false" ]
        [ "$PASSWORD_AUTH" = "no" ]
        [ "$SSH_PUBKEY_AUTHENTICATION" = "yes" ]
        [ "$SSH_PUBKEY" = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey user@workstation" ]

        # Test review card output reflects the new port policy and pubkey
        local card_out
        card_out=$(print_review_card 13)
        echo "$card_out" | grep -Fq "彻底关闭旧端口 22" || fail "review card should show closed legacy port"
        echo "$card_out" | grep -Fq "ssh-ed25519 user@workstation" || fail "review card should show pubkey summary"

        # Test i18n translation for new keys
        set_ui_language en
        [ "$(t '保留旧 SSH 端口:')" = "Keep Legacy SSH Port:" ]
        [ "$(t '旧端口 22 目前仍保持监听。')" = "Legacy port 22 is still listening." ]
    ) || fail "ssh legacy port and pubkey configuration test failed"
}

test_user_password_configuration_and_cli() {
    local isolated_repo="$SANDBOX_DIR/user-pwd-guard"
    cp -a "$ROOT_DIR" "$isolated_repo"
    local config_file="$isolated_repo/config/vps_config.conf"

    # 1. Test saving and loading USER_PASSWORD
    (
        cd "$isolated_repo"
        source lib/core.sh
        source lib/common.sh
        printf '%s\n' \
            'USERNAME=testadm' \
            'USER_PASSWORD=SecretPassword123' > "$config_file"
        chmod 600 "$config_file"
        load_config "$config_file"
        [ "$USERNAME" = "testadm" ]
        [ "$USER_PASSWORD" = "SecretPassword123" ]

        # Test save_config preserves USER_PASSWORD
        save_config "$config_file" $(get_config_var_names)
        grep -q '^USER_PASSWORD=SecretPassword123$' "$config_file" || fail "USER_PASSWORD not saved to config"

        # Test review card displays password status
        PASSWORD_AUTH=no
        local card_out
        card_out=$(print_review_card 13)
        echo "$card_out" | grep -Fq "已设本地密码" || fail "review card should display local password status"
    ) || fail "user password config save and load test failed"

    # 2. Test --help displays --set-password
    local help_out
    help_out=$("$isolated_repo/vps_setup.sh" --help 2>&1)
    echo "$help_out" | grep -Fq -- "--set-password" || fail "--help missing --set-password"

    # 3. Test --set-password in non-interactive mode without password errors gracefully
    local err_out
    if "$isolated_repo/vps_setup.sh" -n --set-password testadm >"$SANDBOX_DIR/pwd_err.out" 2>&1; then
        fail "--set-password should fail when no password is provided in non-interactive mode"
    fi
}

test_safe_config_parser
test_access_guard
test_module_source_guard
test_tui_engine_load
test_tui_noninteractive_fallback
test_tui_eof_cancellation
test_tui_card_input_password_masking
test_apt_lock_wait_guard
test_apply_config_defaults_completeness
test_i18n_translation_and_fallbacks
test_i18n_variable_interpolation
test_eval_elimination_in_user_module
test_root_guard
test_rollback_cli_guard
test_health_report_cli
test_view_config_cli
test_ssh_legacy_port_and_pubkey_configuration
test_user_password_configuration_and_cli
test_docker_install_flag_skip
test_fail2ban_install_flag_skip
test_network_security_sysctl_generation
test_unsafe_install_dir_guard
test_install_default_ref
printf 'Regression checks passed.\n'