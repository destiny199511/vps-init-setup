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

test_install_requires_pinned_remote_source() {
    local help_out
    help_out=$(bash "$ROOT_DIR/install.sh" --help)
    echo "$help_out" | grep -Fq '40 位不可变 Git commit' || \
        fail "install.sh help must require an immutable remote commit"
    echo "$help_out" | grep -Fq 'SHA-256' || \
        fail "install.sh help must document archive integrity verification"
}

test_install_rejects_unpinned_remote_source() {
    local install_input="$SANDBOX_DIR/unpinned-install.sh"
    {
        printf '%s\n' '#!/bin/bash'
        tail -n +2 "$ROOT_DIR/install.sh"
    } > "$install_input"
    if sudo bash "$install_input" --install-dir "$SANDBOX_DIR/install-target" >"$SANDBOX_DIR/unpinned-install.out" 2>&1; then
        fail "remote installer accepted an unpinned source"
    fi
    grep -Fq '40 位不可变 Git commit' "$SANDBOX_DIR/unpinned-install.out" || \
        fail "remote installer did not reject missing immutable commit"
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
                SSH_PUBKEY|ALLOWED_PORTS|DOCKER_INSECURE_REGISTRIES|DOCKER_REGISTRY_MIRRORS|FAIL2BAN_IGNOREIP|BACKUP_GPG_RECIPIENT|SWAP_SIZE|USER_FULLNAME)
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

test_firewall_rule_ordering() {
    (
        cd "$ROOT_DIR"
        source lib/core.sh
        source lib/common.sh
        source modules/06_firewall.sh

        local ufw_log="$SANDBOX_DIR/ufw.log"
        ufw() {
            printf '%s\n' "$*" >> "$ufw_log"
            case "$1" in
                status) printf 'Status: active\n' ;;
                *) return 0 ;;
            esac
        }
        NON_INTERACTIVE=true
        detect_firewall() { printf 'ufw\n'; }
        SSH_PORT=2222
        SSH_KEEP_LEGACY_PORT=true
        HTTP_PORT=80
        HTTPS_PORT=443
        ALLOWED_PORTS=""
        state_mark() { return 0; }
        firewall_main
        local allow_line deny_line
        allow_line=$(grep -n 'allow 2222/tcp' "$ufw_log" | cut -d: -f1 | head -1)
        deny_line=$(grep -n 'default deny incoming' "$ufw_log" | cut -d: -f1 | head -1)
        [ -n "$allow_line" ] && [ -n "$deny_line" ]
        [ "$allow_line" -lt "$deny_line" ] || fail "UFW must allow SSH before default deny incoming"

        local firewalld_log="$SANDBOX_DIR/firewalld.log"
        firewall-cmd() {
            printf '%s\n' "$*" >> "$firewalld_log"
            case "$1" in
                --state) printf 'running\n' ;;
                *) return 0 ;;
            esac
        }
        detect_firewall() { printf 'firewalld\n'; }
        firewall_main
        local fwd_allow_line fwd_drop_line
        fwd_allow_line=$(grep -n -F -- '--zone=drop --add-port=2222/tcp' "$firewalld_log" | cut -d: -f1 | head -1)
        fwd_drop_line=$(grep -n -F -- '--set-default-zone=drop' "$firewalld_log" | cut -d: -f1 | head -1)
        [ -n "$fwd_allow_line" ] && [ -n "$fwd_drop_line" ]
        [ "$fwd_allow_line" -lt "$fwd_drop_line" ] || fail "FirewallD must add SSH port before setting drop zone"
    ) || fail "firewall rule ordering"
}

test_dns_timeout_prevalidation() {
    (
        cd "$ROOT_DIR"
        source lib/core.sh
        source lib/common.sh
        source modules/03_dns.sh
        NON_INTERACTIVE=true
        PRIMARY_DNS=1.1.1.1
        SECONDARY_DNS=8.8.8.8
        DNS_LOOKUP_TIMEOUT="0"
        backup_file() { fail "backup_file should not be called on invalid timeout"; }
        ! dns_main
        DNS_LOOKUP_TIMEOUT="-5"
        ! dns_main
        DNS_LOOKUP_TIMEOUT="invalid"
        ! dns_main
    ) || fail "dns timeout prevalidation"
}

test_network_security_sysctl_generation() {
    (
        cd "$ROOT_DIR"
        source lib/core.sh
        source lib/common.sh
        source modules/09_network.sh
        local test_dir="$SANDBOX_DIR/network-sysctl"
        mkdir -p "$test_dir/backups"
        LOG_FILE="$test_dir/log"
        AUDIT_LOG="$test_dir/audit"
        BACKUPS_DIR="$test_dir/backups"
        BACKUP_REGISTRY="$test_dir/registry"
        STATE_FILE="$test_dir/state"
        SYSCTL_CONFIG_FILE="$test_dir/99-vps-network.conf"
        ENABLE_BBR=false
        printf 'previous=value\n' > "$SYSCTL_CONFIG_FILE"
        sysctl() { return 0; }
        network_main
        grep -Fxq 'net.ipv4.tcp_fastopen = 3' "$SYSCTL_CONFIG_FILE"
        grep -Fxq '# Security Hardening - Anti-Spoofing & Anti-DDoS' "$SYSCTL_CONFIG_FILE"
        printf 'previous=value\n' > "$SYSCTL_CONFIG_FILE"
        sysctl() { return 1; }
        ! network_main
        grep -Fxq 'previous=value' "$SYSCTL_CONFIG_FILE"
    ) || fail "network sysctl generation and failure rollback"
}

test_backup_and_rollback_baseline() {
    (
        cd "$ROOT_DIR"
        source lib/core.sh
        local test_dir="$SANDBOX_DIR/backup-rollback"
        mkdir -p "$test_dir/backups"
        LOG_FILE="$test_dir/log"
        AUDIT_LOG="$test_dir/audit"
        BACKUPS_DIR="$test_dir/backups"
        BACKUP_REGISTRY="$test_dir/registry"
        local source_file="$test_dir/source"
        printf 'baseline\n' > "$source_file"
        local first_snapshot second_snapshot
        first_snapshot="$(backup_file "$source_file")"
        [ -f "$first_snapshot" ]
        [ "$(stat -c '%a' "$first_snapshot")" = "600" ]
        printf 'intermediate\n' > "$source_file"
        second_snapshot="$(backup_file "$source_file")"
        [ -f "$second_snapshot" ]
        printf 'latest\n' > "$source_file"
        mkdir "$test_dir/directory"
        printf 'directory-baseline\n' > "$test_dir/directory/item"
        backup_file "$test_dir/directory" >/dev/null
        printf 'directory-changed\n' > "$test_dir/directory/item"
        ln -s target-one "$test_dir/link"
        backup_file "$test_dir/link" >/dev/null
        rm "$test_dir/link"
        ln -s target-two "$test_dir/link"
        backup_file "$test_dir/created-later" >/dev/null
        printf 'created\n' > "$test_dir/created-later"
        rollback_all >/dev/null
        [ "$(cat "$source_file")" = 'baseline' ]
        [ "$(cat "$test_dir/directory/item")" = 'directory-baseline' ]
        [ "$(readlink "$test_dir/link")" = 'target-one' ]
        [ ! -e "$test_dir/created-later" ]
    ) || fail "backup must return a private snapshot and rollback to the first baseline"
}

test_dry_run_has_no_workspace_writes() {
    local isolated_repo="$SANDBOX_DIR/dry-run"
    local before_manifest="$SANDBOX_DIR/dry-run-before"
    local after_manifest="$SANDBOX_DIR/dry-run-after"
    cp -a "$ROOT_DIR" "$isolated_repo"
    (
        cd "$isolated_repo"
        find . -path './.git' -prune -o -type f -printf '%P:%s:' -exec sha256sum {} \; | sort > "$before_manifest"
        SKIP_ROOT_CHECK=true ./vps_setup.sh -n -d --modules 00_preflight > "$SANDBOX_DIR/dry-run.out" 2>&1
        find . -path './.git' -prune -o -type f -printf '%P:%s:' -exec sha256sum {} \; | sort > "$after_manifest"
    ) || fail "dry-run execution"
    diff -u "$before_manifest" "$after_manifest" >/dev/null || fail "dry-run wrote to the workspace"
}

test_irreversible_cleanup_guard() {
    (
        cd "$ROOT_DIR"
        source lib/core.sh
        source lib/common.sh
        source modules/13_cleanup.sh
        LOG_FILE="$SANDBOX_DIR/cleanup.log"
        unset CLEAN_PKG_CACHE CLEAN_JOURNAL CLEAN_TEMP IRREVERSIBLE_CLEANUP_CONFIRMED
        apply_config_defaults
        [ "$CLEAN_PKG_CACHE" = false ]
        [ "$CLEAN_JOURNAL" = false ]
        [ "$CLEAN_TEMP" = false ]
        ! require_irreversible_cleanup_confirmation
        IRREVERSIBLE_CLEANUP_CONFIRMED=true
        require_irreversible_cleanup_confirmation
    ) || fail "irreversible cleanup requires explicit confirmation"
}

test_docker_repository_key_verification() {
    (
        cd "$ROOT_DIR"
        source lib/core.sh
        source modules/08_docker.sh
        [ "$DOCKER_GPG_FINGERPRINT" = '9DC858229FC7DD38854AE2D88D81803C0EBFCD88' ]
        local test_dir="$SANDBOX_DIR/docker-key"
        local key_dir="$test_dir/keyrings"
        local source_file="$test_dir/sources/docker.list"
        LOG_FILE="$test_dir/log"
        detect_os_id() { printf 'debian\n'; }
        lsb_release() { printf 'bookworm\n'; }
        dpkg() { printf 'amd64\n'; }
        curl() {
            local output
            while [ "$#" -gt 0 ]; do
                if [ "$1" = '-o' ]; then
                    output="$2"
                    shift 2
                else
                    shift
                fi
            done
            printf 'key-data\n' > "$output"
        }
        gpg() {
            if [[ " $* " == *' --show-keys '* ]]; then
                printf 'fpr:::::::::9DC858229FC7DD38854AE2D88D81803C0EBFCD88:\n'
            else
                local output=""
                while [ "$#" -gt 0 ]; do
                    if [ "$1" = '--output' ]; then
                        output="$2"
                        shift 2
                    else
                        shift
                    fi
                done
                printf 'dearmored\n' > "$output"
            fi
        }
        apt_update() { return 0; }
        DOCKER_APT_KEYRING_DIR="$key_dir" DOCKER_APT_KEY_FILE="$key_dir/docker.gpg" \
            DOCKER_APT_SOURCE_FILE="$source_file" docker_configure_apt_repository
        test -s "$key_dir/docker.gpg"
        grep -Fqx "deb [arch=amd64 signed-by=$key_dir/docker.gpg] https://download.docker.com/linux/debian bookworm stable" "$source_file"
        rm -f "$key_dir/docker.gpg" "$source_file"
        gpg() { printf 'fpr:::::::::BADFINGERPRINT:\n'; }
        ! DOCKER_APT_KEYRING_DIR="$key_dir" DOCKER_APT_KEY_FILE="$key_dir/docker.gpg" \
            DOCKER_APT_SOURCE_FILE="$source_file" docker_configure_apt_repository
        test ! -e "$key_dir/docker.gpg"
        test ! -e "$source_file"
    ) || fail "Docker repository key verification"
}

test_account_security_baseline() {
    (
        cd "$ROOT_DIR"
        source lib/core.sh
        source lib/common.sh
        source modules/12_security.sh
        local test_dir="$SANDBOX_DIR/account-baseline"
        mkdir -p "$test_dir/backups"
        LOG_FILE="$test_dir/log"
        AUDIT_LOG="$test_dir/audit"
        BACKUPS_DIR="$test_dir/backups"
        BACKUP_REGISTRY="$test_dir/registry"
        LOGIN_DEFS_FILE="$test_dir/login.defs"
        PWQUALITY_CONF_FILE="$test_dir/pwquality.conf"
        printf '%s\n' '# system defaults' 'PASS_MAX_DAYS 99999' 'UMASK 022' > "$LOGIN_DEFS_FILE"
        printf '%s\n' '# quality defaults' 'minlen = 8' 'retry = 1' > "$PWQUALITY_CONF_FILE"
        PASS_MAX_DAYS=365
        PASS_MIN_DAYS=1
        PASS_WARN_AGE=7
        DEFAULT_UMASK=027
        PWQUALITY_MINLEN=14
        PWQUALITY_MINCLASS=4
        PWQUALITY_RETRY=3
        security_apply_account_baseline
        grep -Fxq 'PASS_MAX_DAYS 365' "$LOGIN_DEFS_FILE"
        grep -Fxq 'PASS_MIN_DAYS 1' "$LOGIN_DEFS_FILE"
        grep -Fxq 'PASS_WARN_AGE 7' "$LOGIN_DEFS_FILE"
        grep -Fxq 'UMASK 027' "$LOGIN_DEFS_FILE"
        grep -Fxq 'minlen = 14' "$PWQUALITY_CONF_FILE"
        grep -Fxq 'minclass = 4' "$PWQUALITY_CONF_FILE"
        grep -Fxq 'retry = 3' "$PWQUALITY_CONF_FILE"
        cp "$LOGIN_DEFS_FILE" "$test_dir/login.expected"
        PWQUALITY_MINLEN=11
        ! security_apply_account_baseline
        cmp -s "$LOGIN_DEFS_FILE" "$test_dir/login.expected"

        # Missing pwquality.conf triggers package install attempt
        rm -f "$PWQUALITY_CONF_FILE"
        local called_install=false
        install_pkg() {
            called_install=true
            [ "$1" = "libpam-pwquality" ] || return 1
            printf '%s\n' 'minlen = 9' > "$PWQUALITY_CONF_FILE"
        }
        PKG_MGR="apt"
        PWQUALITY_MINLEN=14
        security_apply_account_baseline
        [ "$called_install" = true ]
        grep -Fxq 'minlen = 14' "$PWQUALITY_CONF_FILE"
    ) || fail "account security baseline"
}

test_sudo_nopasswd_rejected_before_user_changes() {
    (
        cd "$ROOT_DIR"
        source lib/core.sh
        source lib/common.sh
        source modules/04_user.sh
        LOG_FILE="$SANDBOX_DIR/sudo-policy.log"
        USERNAME=policytest
        SUDO_NOPASSWD=true
        id() {
            if [ "${1:-}" = '-u' ]; then
                printf '0\n'
                return 0
            fi
            return 1
        }
        useradd() {
            touch "$SANDBOX_DIR/useradd-called"
            return 0
        }
        ! user_main
        test ! -e "$SANDBOX_DIR/useradd-called"
    ) || fail "SUDO_NOPASSWD rejection must precede user creation"
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

    # Test rollback when a valid registry exists
    local trans_dir="$isolated_repo/backups/transactions/test_trans"
    mkdir -p "$trans_dir"
    local target_file="$SANDBOX_DIR/rollback_target.txt"
    local snap_file="$trans_dir/target.snap"
    printf 'original-content\n' > "$snap_file"
    printf 'modified-content\n' > "$target_file"
    printf '%s|%s|file|644|\n' "$target_file" "$snap_file" > "$trans_dir/registry.tsv"
    output=$(SKIP_ROOT_CHECK=true "$isolated_repo/vps_setup.sh" -n -a --rollback 2>&1)
    echo "$output" | grep -Fq "受跟踪的配置文件已恢复" || fail "rollback with registry should succeed"
    [ "$(cat "$target_file")" = "original-content" ] || fail "target file not restored properly"
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

    # A production port migration must retain the old port even when a legacy
    # configuration requests its removal; closing it needs a separate change.
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

        # The review card clarifies that production policy forces preservation of legacy ports,
        # while the migration policy always keeps the old listening port before any SSH files are edited.
        local card_out
        card_out=$(print_review_card 13)
        echo "$card_out" | grep -Fq "生产保护强制保留" || fail "review card should show production legacy port protection"
        echo "$card_out" | grep -Fq "ssh-ed25519 user@workstation" || fail "review card should show pubkey summary"

        source modules/05_ssh.sh
        local resolved_ports
        ssh_resolve_migration_ports resolved_ports "22" "24822" false
        [ "$resolved_ports" = "22 24822" ] || fail "SSH migration must preserve the legacy port"
        ssh_resolve_migration_ports resolved_ports "22 24822" "24822" true
        [ "$resolved_ports" = "22 24822" ] || fail "SSH migration must not duplicate an existing target port"

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

    # 1. Reject passwords from persistent configuration and accept only the
    # one-time environment variable.
    (
        cd "$isolated_repo"
        source lib/core.sh
        source lib/common.sh
        printf '%s\n' \
            'USERNAME=testadm' \
            'USER_PASSWORD=SecretPassword123' > "$config_file"
        chmod 600 "$config_file"
        if load_config "$config_file"; then
            fail "USER_PASSWORD in configuration must be rejected"
        fi
        [ -z "${USER_PASSWORD:-}" ]

        USERNAME=testadm
        VPS_SETUP_USER_PASSWORD=SecretPassword123
        apply_config_defaults
        [ "$USER_PASSWORD" = "SecretPassword123" ]
        # The password must live only in this shell, never inherited by child processes.
        [ "$(python3 -c 'import os; print(os.environ.get("USER_PASSWORD", ""))')" = "" ] || \
            fail "USER_PASSWORD leaked into child processes"
        save_config "$config_file" $(get_config_var_names)
        ! grep -q '^USER_PASSWORD=' "$config_file" || fail "USER_PASSWORD must not be saved to config"

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

    # 4. A password for an account that does not exist must not be staged in
    # configuration now that persistent password storage is forbidden.
    if SKIP_ROOT_CHECK=true VPS_SETUP_USER_PASSWORD=SecretPassword123 \
        "$isolated_repo/vps_setup.sh" -n --set-password notcreated >"$SANDBOX_DIR/pwd_missing_user.out" 2>&1; then
        fail "--set-password must reject a non-existent user"
    fi
    grep -Fq '不会持久化密码' "$SANDBOX_DIR/pwd_missing_user.out" || \
        fail "missing-user password rejection message"
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
test_firewall_rule_ordering
test_dns_timeout_prevalidation
test_network_security_sysctl_generation
test_backup_and_rollback_baseline
test_dry_run_has_no_workspace_writes
test_irreversible_cleanup_guard
test_docker_repository_key_verification
test_account_security_baseline
test_sudo_nopasswd_rejected_before_user_changes
test_unsafe_install_dir_guard
test_install_requires_pinned_remote_source
printf 'Regression checks passed.\n'