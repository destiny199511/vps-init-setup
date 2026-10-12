#!/usr/bin/env bash
#
# Security Module - Install and configure security scanning/auditing tools
#

security_info() {
    echo "Install and configure security scanning and auditing tools"
}

security_prerequisites() {
    return 0
}

security_validate_integer_range() {
    local value="$1"
    local min_value="$2"
    local max_value="$3"
    local setting_name="$4"

    if [[ ! "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt "$min_value" ] || [ "$value" -gt "$max_value" ]; then
        log_error "$setting_name must be an integer between $min_value and $max_value: $value"
        return 1
    fi
}

security_restore_file_snapshot() {
    local target="$1"
    local snapshot="$2"
    [ -n "$snapshot" ] && [ -f "$snapshot" ] && cp -p "$snapshot" "$target"
}

security_render_login_defs_baseline() {
    local source="$1"
    local destination="$2"
    local pass_max_days="$3"
    local pass_min_days="$4"
    local pass_warn_age="$5"
    local default_umask="$6"

    awk -v pass_max_days="$pass_max_days" -v pass_min_days="$pass_min_days" \
        -v pass_warn_age="$pass_warn_age" -v default_umask="$default_umask" '
        /^[[:space:]]*#?[[:space:]]*PASS_MAX_DAYS[[:space:]]+/ {
            if (!seen_max++) print "PASS_MAX_DAYS " pass_max_days
            next
        }
        /^[[:space:]]*#?[[:space:]]*PASS_MIN_DAYS[[:space:]]+/ {
            if (!seen_min++) print "PASS_MIN_DAYS " pass_min_days
            next
        }
        /^[[:space:]]*#?[[:space:]]*PASS_WARN_AGE[[:space:]]+/ {
            if (!seen_warn++) print "PASS_WARN_AGE " pass_warn_age
            next
        }
        /^[[:space:]]*#?[[:space:]]*UMASK[[:space:]]+/ {
            if (!seen_umask++) print "UMASK " default_umask
            next
        }
        { print }
        END {
            if (!seen_max) print "PASS_MAX_DAYS " pass_max_days
            if (!seen_min) print "PASS_MIN_DAYS " pass_min_days
            if (!seen_warn) print "PASS_WARN_AGE " pass_warn_age
            if (!seen_umask) print "UMASK " default_umask
        }
    ' "$source" > "$destination"
}

security_render_pwquality_baseline() {
    local source="$1"
    local destination="$2"
    local minimum_length="$3"
    local minimum_classes="$4"
    local retries="$5"

    awk -v minimum_length="$minimum_length" -v minimum_classes="$minimum_classes" -v retries="$retries" '
        /^[[:space:]]*#?[[:space:]]*minlen[[:space:]]*=/ {
            if (!seen_length++) print "minlen = " minimum_length
            next
        }
        /^[[:space:]]*#?[[:space:]]*minclass[[:space:]]*=/ {
            if (!seen_classes++) print "minclass = " minimum_classes
            next
        }
        /^[[:space:]]*#?[[:space:]]*retry[[:space:]]*=/ {
            if (!seen_retry++) print "retry = " retries
            next
        }
        { print }
        END {
            if (!seen_length) print "minlen = " minimum_length
            if (!seen_classes) print "minclass = " minimum_classes
            if (!seen_retry) print "retry = " retries
        }
    ' "$source" > "$destination"
}

security_ensure_pwquality_file() {
    local pwquality_conf="$1"
    [ -f "$pwquality_conf" ] && return 0

    local pkg=""
    case "${PKG_MGR:-$(detect_package_manager 2>/dev/null || true)}" in
        apt|deb)
            pkg="libpam-pwquality"
            ;;
        dnf|yum|rpm)
            pkg="libpwquality"
            ;;
        zypper)
            pkg="pam_pwquality"
            ;;
        pacman)
            pkg="libpwquality"
            ;;
        apk)
            pkg="linux-pam"
            ;;
    esac

    if [ -n "$pkg" ] && declare -F install_pkg >/dev/null 2>&1; then
        log_info "Installing $pkg to provide password quality configuration..."
        install_pkg "$pkg" || log_warn "Failed to install $pkg automatically"
    fi

    [ -f "$pwquality_conf" ]
}

security_apply_account_baseline() {
    local login_defs="${LOGIN_DEFS_FILE:-/etc/login.defs}"
    local pwquality_conf="${PWQUALITY_CONF_FILE:-/etc/security/pwquality.conf}"
    local pass_max_days="${PASS_MAX_DAYS:-365}"
    local pass_min_days="${PASS_MIN_DAYS:-1}"
    local pass_warn_age="${PASS_WARN_AGE:-7}"
    local default_umask="${DEFAULT_UMASK:-027}"
    local minimum_length="${PWQUALITY_MINLEN:-14}"
    local minimum_classes="${PWQUALITY_MINCLASS:-4}"
    local retries="${PWQUALITY_RETRY:-3}"
    local login_candidate pwquality_candidate login_backup pwquality_backup

    security_validate_integer_range "$pass_max_days" 1 99999 PASS_MAX_DAYS || return 1
    security_validate_integer_range "$pass_min_days" 0 "$pass_max_days" PASS_MIN_DAYS || return 1
    security_validate_integer_range "$pass_warn_age" 1 99999 PASS_WARN_AGE || return 1
    security_validate_integer_range "$minimum_length" 12 128 PWQUALITY_MINLEN || return 1
    security_validate_integer_range "$minimum_classes" 1 4 PWQUALITY_MINCLASS || return 1
    security_validate_integer_range "$retries" 1 10 PWQUALITY_RETRY || return 1
    if [[ ! "$default_umask" =~ ^[0-7]{3}$ ]]; then
        log_error "DEFAULT_UMASK must be a three-digit octal mode: $default_umask"
        return 1
    fi
    if [ ! -f "$login_defs" ]; then
        log_error "Account security baseline requires $login_defs"
        return 1
    fi
    if ! security_ensure_pwquality_file "$pwquality_conf"; then
        log_error "Account security baseline requires $pwquality_conf"
        log_error "Install the distribution-provided PAM password-quality package before retrying"
        return 1
    fi

    login_candidate="$(mktemp "$(dirname "$login_defs")/.$(basename "$login_defs").XXXXXX")" || return 1
    pwquality_candidate="$(mktemp "$(dirname "$pwquality_conf")/.$(basename "$pwquality_conf").XXXXXX")" || {
        rm -f "$login_candidate"
        return 1
    }
    if ! security_render_login_defs_baseline "$login_defs" "$login_candidate" "$pass_max_days" \
        "$pass_min_days" "$pass_warn_age" "$default_umask" || \
       ! security_render_pwquality_baseline "$pwquality_conf" "$pwquality_candidate" "$minimum_length" \
        "$minimum_classes" "$retries"; then
        rm -f "$login_candidate" "$pwquality_candidate"
        return 1
    fi
    login_backup="$(backup_file "$login_defs")" || {
        rm -f "$login_candidate" "$pwquality_candidate"
        return 1
    }
    pwquality_backup="$(backup_file "$pwquality_conf")" || {
        rm -f "$login_candidate" "$pwquality_candidate"
        return 1
    }
    if ! install -m 644 "$login_candidate" "$login_defs" || ! install -m 644 "$pwquality_candidate" "$pwquality_conf"; then
        log_error "Failed to install account security baseline; restoring both files"
        security_restore_file_snapshot "$login_defs" "$login_backup" || true
        security_restore_file_snapshot "$pwquality_conf" "$pwquality_backup" || true
        rm -f "$login_candidate" "$pwquality_candidate"
        return 1
    fi
    rm -f "$login_candidate" "$pwquality_candidate"
    audit "SECURITY_ACCOUNT_BASELINE" "pass_max_days=$pass_max_days pass_min_days=$pass_min_days pass_warn_age=$pass_warn_age umask=$default_umask minlen=$minimum_length minclass=$minimum_classes retry=$retries"
    log_info "Account password-aging, umask, and pwquality baseline configured"
}

security_main() {
    log_info "Starting security configuration..."

    local install_scanners lynis_enabled rkhunter_enabled chkrootkit_enabled
    local auditd_enabled selinux_enabled account_baseline_enabled

    install_scanners=false
    lynis_enabled=false
    rkhunter_enabled=false
    chkrootkit_enabled=false
    auditd_enabled=false
    selinux_enabled=false
    account_baseline_enabled="${ENFORCE_ACCOUNT_SECURITY_BASELINE:-true}"

    if [ "${NON_INTERACTIVE:-false}" = "true" ]; then
        # Prefer wizard/config keys; keep SECURITY_* as optional overrides.
        install_scanners="${SECURITY_SCANNERS_ENABLED:-false}"
        lynis_enabled="${SECURITY_LYNIS_ENABLED:-false}"
        rkhunter_enabled="${SECURITY_RKHUNTER_ENABLED:-false}"
        chkrootkit_enabled="${SECURITY_CHKROOTKIT_ENABLED:-false}"
        if [ -n "${INSTALL_AUDITD:-}" ]; then
            case "${INSTALL_AUDITD}" in
                true|yes|1|on|ON) auditd_enabled=true ;;
                *) auditd_enabled=false ;;
            esac
        else
            auditd_enabled="${SECURITY_AUDITD_ENABLED:-false}"
        fi
        if [ -n "${ENABLE_SELINUX_CHECK:-}" ]; then
            case "${ENABLE_SELINUX_CHECK}" in
                true|yes|1|on|ON) selinux_enabled=true ;;
                *) selinux_enabled=false ;;
            esac
        else
            selinux_enabled="${SECURITY_SELINUX_ENABLED:-false}"
        fi
    else
        read -r -p "Install security scanners (Lynis, rkhunter)? [Y/n] " choice
        case "$choice" in
            n|N|no|NO) install_scanners=false ;;
            *) install_scanners=true ;;
        esac

        if [ "$install_scanners" = "true" ]; then
            read -r -p "Install Lynis? [Y/n] " choice
            case "$choice" in
                n|N|no|NO) lynis_enabled=false ;;
                *) lynis_enabled=true ;;
            esac

            read -r -p "Install rkhunter? [Y/n] " choice
            case "$choice" in
                n|N|no|NO) rkhunter_enabled=false ;;
                *) rkhunter_enabled=true ;;
            esac

            read -r -p "Install chkrootkit? [y/N] " choice
            case "$choice" in
                y|Y|yes|Yes) chkrootkit_enabled=true ;;
                *) chkrootkit_enabled=false ;;
            esac
        fi

        read -r -p "Enable auditd (system auditing)? [Y/n] " choice
        case "$choice" in
            n|N|no|NO) auditd_enabled=false ;;
            *) auditd_enabled=true ;;
        esac

        read -r -p "Check/enforce MAC policies (SELinux/AppArmor)? [y/N] " choice
        case "$choice" in
            y|Y|yes|Yes) selinux_enabled=true ;;
            *) selinux_enabled=false ;;
        esac
    fi

     if [ "$install_scanners" = "false" ] && [ "$auditd_enabled" = "false" ] && [ "$selinux_enabled" = "false" ] && \
         [ "$account_baseline_enabled" != "true" ]; then
        log_info "No security components selected - skipping"
        state_mark "security" "completed"
        return 0
    fi

    local changes_made=false

    if [ "$account_baseline_enabled" = "true" ]; then
        security_apply_account_baseline || return 1
        changes_made=true
    fi

    # Install Lynis
    if [ "$lynis_enabled" = "true" ]; then
        log_info "Installing Lynis..."
        if ! command -v lynis >/dev/null 2>&1; then
            case "$(detect_package_manager)" in
                apt|deb|yum|dnf|rpm)
                    install_package lynis
                    ;;
                *)
                    log_error "Lynis is unavailable from a verified distribution package source on this platform"
                    log_error "Install a vendor-verified package manually, then rerun the security module"
                    return 1
                    ;;
            esac

            if command -v lynis >/dev/null 2>&1; then
                lynis update info 2>/dev/null || true
            fi

            changes_made=true
            log_info "Lynis installed successfully"
            audit "SECURITY_LYNIS_INSTALLED"
        else
            log_info "Lynis already installed"
        fi
    fi

    # Install rkhunter
    if [ "$rkhunter_enabled" = "true" ]; then
        log_info "Installing rkhunter..."
        if ! command -v rkhunter >/dev/null 2>&1; then
            install_package rkhunter

            if command -v rkhunter >/dev/null 2>&1; then
                rkhunter --propupd 2>/dev/null || true
            fi

            changes_made=true
            log_info "rkhunter installed successfully"
            audit "SECURITY_RKHUNTER_INSTALLED"
        else
            log_info "rkhunter already installed"
        fi
    fi

    # Install chkrootkit
    if [ "$chkrootkit_enabled" = "true" ]; then
        log_info "Installing chkrootkit..."
        if ! command -v chkrootkit >/dev/null 2>&1; then
            install_package chkrootkit
            changes_made=true
            log_info "chkrootkit installed successfully"
            audit "SECURITY_CHKROOTKIT_INSTALLED"
        else
            log_info "chkrootkit already installed"
        fi
    fi

    # Configure auditd
    if [ "$auditd_enabled" = "true" ]; then
        log_info "Configuring auditd..."
        if ! command -v auditd >/dev/null 2>&1; then
            install_package auditd audispd-plugins
        fi

        systemctl enable --now auditd 2>/dev/null || \
            service auditd enable && service auditd start 2>/dev/null || true

        if [ -f /etc/audit/rules.d/audit.rules ]; then
            cp /etc/audit/rules.d/audit.rules "/etc/audit/rules.d/audit.rules.backup.$(date +%s)"
        fi

        cat > /etc/audit/rules.d/audit.rules << 'EOFAUDIT'
# Audit rules - Generated by VPS Auto-Setup
-D
-b 8192
-f 1

# Watch critical files for changes
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/sudoers -p wa -k sudoers
-w /etc/ssh/sshd_config -p wa -k sshd
-w /etc/hosts -p wa -k hosts
-w /usr/bin/sudo -p x -k priv_cmd
-w /usr/bin/su -p x -k priv_cmd

# Monitor kernel module loading/unloading
-w /sbin/insmod -p x -k modules
-w /sbin/rmmod -p x -k modules
-w /sbin/modprobe -p x -k modules
-a always,exit -F arch=b64 -S init_module,finit_module,delete_module -k modules

# Optionally make immutable (uncomment at your risk)
# -e 2
EOFAUDIT

        systemctl restart auditd 2>/dev/null || service auditd restart 2>/dev/null || true

        if systemctl is-active --quiet auditd || service auditd status >/dev/null 2>&1; then
            log_info "auditd configured and running"
            changes_made=true
            audit "SECURITY_AUDITD_CONFIGURED"
        else
            log_warn "auditd failed to start properly"
        fi
    fi

    # SELinux / AppArmor
    if [ "$selinux_enabled" = "true" ]; then
        log_info "Checking MAC status..."

        if [ -f /selinux/enforce ] || [ -f /etc/selinux/config ]; then
            local selinux_mode
            selinux_mode=$(getenforce 2>/dev/null || sestatus 2>/dev/null | awk '/Current mode/ {print $NF}')
            log_info "SELinux mode: ${selinux_mode:-unknown}"

            if [ "$selinux_mode" != "Enforcing" ]; then
                if [ "${NON_INTERACTIVE:-false}" = "false" ]; then
                    read -r -p "Set SELinux to enforcing mode? [y/N] " choice
                    case "$choice" in
                        y|Y|yes|Yes)
                            if [ -f /etc/selinux/config ]; then
                                sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config
                                setenforce 1
                                log_info "SELinux set to enforcing mode"
                            fi
                            ;;
                    esac
                fi
            fi
            changes_made=true
            audit "SECURITY_SELINUX_CHECKED" "mode=${selinux_mode}"
        fi

        if [ -f /sys/kernel/security/apparmor/profiles ]; then
            log_info "AppArmor is active"
            if command -v aa-status >/dev/null 2>&1; then
                aa-status 2>/dev/null | head -10 || true
            fi
            changes_made=true
            audit "SECURITY_APPARMOR_CHECKED"
        fi
    fi

    # Create security scan script
    if [ "$install_scanners" = "true" ] && [ -n "$(command -v lynis 2>/dev/null)" ]; then
        local security_script
        security_script="/usr/local/bin/vps-security-scan.sh"
        cat > "$security_script" << 'EOF'
#!/bin/sh
# Daily security scan script
/usr/sbin/lynis audit system --cronjob --quiet 2>&1 | logger -t lynis
[ -x /usr/bin/rkhunter ] && /usr/bin/rkhunter --cronjob --report-warnings-only 2>&1 | logger -t rkhunter
EOF
        chmod 700 "$security_script"

        # Add to weekly cron
        local cron_file="/etc/cron.weekly/vps-security-scan"
        ln -sf "$security_script" "$cron_file" 2>/dev/null || true

        changes_made=true
        audit "SECURITY_SCAN_SCRIPT_CREATED"
    fi

    if [ "$changes_made" = "true" ]; then
        state_mark "security" "completed"
    else
        state_mark "security" "completed"
    fi

    log_info "Security configuration completed"
}

# Allow sourcing without execution
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    return 0
fi

# If executed directly, run the main function
security_main "$@"