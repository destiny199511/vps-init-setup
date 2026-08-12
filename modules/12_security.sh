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

security_main() {
    log_info "Starting security configuration..."

    local install_scanners lynis_enabled rkhunter_enabled chkrootkit_enabled
    local auditd_enabled selinux_enabled

    install_scanners=false
    lynis_enabled=false
    rkhunter_enabled=false
    chkrootkit_enabled=false
    auditd_enabled=false
    selinux_enabled=false

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

    if [ "$install_scanners" = "false" ] && [ "$auditd_enabled" = "false" ] && [ "$selinux_enabled" = "false" ]; then
        log_info "No security components selected - skipping"
        state_mark "security" "completed"
        return 0
    fi

    local changes_made=false

    # Install Lynis
    if [ "$lynis_enabled" = "true" ]; then
        log_info "Installing Lynis..."
        if ! command -v lynis >/dev/null 2>&1; then
            case "$(detect_package_manager)" in
                apt|deb|yum|dnf|rpm)
                    install_package lynis
                    ;;
                *)
                    install_package pip3
                    pip3 install lynis 2>/dev/null || true
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