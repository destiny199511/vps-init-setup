#!/bin/sh
#
# Fail2ban Module - Install and configure Fail2ban for intrusion prevention
#

fail2ban_info() {
    echo "Install and configure Fail2ban with SSH protection"
}

fail2ban_prerequisites() {
    return 0
}

fail2ban_main() {
    log_info "Starting Fail2ban installation and configuration..."
    
    # Check if fail2ban is already installed
    if command -v fail2ban-client >/dev/null 2>&1; then
        log_info "Fail2ban is already installed"
    else
        log_info "Installing Fail2ban..."
        install_package fail2ban
        
        if ! command -v fail2ban-client >/dev/null 2>&1; then
            log_error "Failed to install Fail2ban"
            return 1
        fi
    fi
    
    # Backup existing configuration
    local fail2ban_backup
    fail2ban_backup=$(backup_file "/etc/fail2ban/jail.local") || true
    fail2ban_backup=$(backup_file "/etc/fail2ban/jail.d") || true
    
    # Get SSH port for configuration
    local ssh_port
    ssh_port=$(grep '^Port' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "22")
    
    # Determine ban settings
    local ban_time findtime maxretry
    
    if [ "${NON_INTERACTIVE:-false}" = "true" ]; then
        ban_time="${FAIL2BAN_BAN_TIME:-3600}"      # 1 hour
        findtime="${FAIL2BAN_FINDTIME:-600}"       # 10 minutes
        maxretry="${FAIL2BAN_MAXRETRY:-3}"
        email_action="${FAIL2BAN_EMAIL_ACTION:-}"
        dest_email="${FAIL2BAN_DEST_EMAIL:-root@localhost}"
        sendername="${FAIL2BAN_SENDER_NAME:-Fail2Ban}"
        sender_email="${FAIL2BAN_SENDER_EMAIL:-fail2ban@localhost}"
    else
        echo "Fail2ban Configuration:"
        echo "-----------------------"
        
        read -r -p "Ban duration (seconds) [3600]: " choice
        [ -z "$choice" ] && choice=3600
        ban_time="$choice"
        
        read -r -p "Find time (seconds) [600]: " choice
        [ -z "$choice" ] && choice=600
        findtime="$choice"
        
        read -r -p "Max retries before ban [3]: " choice
        [ -z "$choice" ] && choice=3
        maxretry="$choice"
        
        # Email notifications
        printf '\033[1;33m'
        read -r -p "Enable email notifications? [y/N] " choice
        printf '\033[0m\n'
        case "$choice" in
            y|Y|yes|Yes)
                read -r -p "Destination email [root@localhost]: " choice
                [ -z "$choice" ] && choice="root@localhost"
                dest_email="$choice"
                
                read -r -p "Sender name [Fail2Ban]: " choice
                [ -z "$choice" ] && choice="Fail2Ban"
                sendername="$choice"
                
                read -r -p "Sender email [fail2ban@localhost]: " choice
                [ -z "$choice" ] && choice="fail2ban@localhost"
                sender_email="$choice"
                
                email_action="action_mwl"
                ;;
            *)
                email_action="action_"
                ;;
        esac
    fi
    
    # Validate numeric values
    if ! echo "$ban_time" | grep -qE '^[0-9]+$' || [ "$ban_time" -lt 60 ]; then
        log_warn "Invalid ban time: $ban_time, using 3600"
        ban_time=3600
    fi
    
    if ! echo "$findtime" | grep -qE '^[0-9]+$' || [ "$findtime" -lt 60 ]; then
        log_warn "Invalid find time: $findtime, using 600"
        findtime=600
    fi
    
    if ! echo "$maxretry" | grep -qE '^[0-9]+$' || [ "$maxretry" -lt 1 ] || [ "$maxretry" -gt 10 ]; then
        log_warn "Invalid max retry: $maxretry, using 3"
        maxretry=3
    fi
    
    # Check if similar configuration already exists
    local config_exists=false
    if [ -f /etc/fail2ban/jail.local ]; then
        if grep -q "^\\[sshd\\]" /etc/fail2ban/jail.local && \
           grep -q "enabled\s*=\s*true" /etc/fail2ban/jail.local && \
           grep -q "port.*$ssh_port" /etc/fail2ban/jail.local; then
            config_exists=true
        fi
    fi
    
    if [ "$config_exists" = "true" ] && [ "${FORCE:-false}" != "true" ]; then
        # Check if values match
        local current_bantime current_findtime current_maxretry
        current_bantime=$(grep -A 20 "\[sshd\]" /etc/fail2ban/jail.local | grep "bantime" | tail -1 | cut -d= -f2 | tr -d ' ')
        current_findtime=$(grep -A 20 "\[sshd\]" /etc/fail2ban/jail.local | grep "findtime" | tail -1 | cut -d= -f2 | tr -d ' ')
        current_maxretry=$(grep -A 20 "\[sshd\]" /etc/fail2ban/jail.local | grep "maxretry" | tail -1 | cut -d= -f2 | tr -d ' ')
        
        if [ "${current_bantime:-0}" = "$ban_time" ] && \
           [ "${current_findtime:-0}" = "$findtime" ] && \
           [ "${current_maxretry:-0}" = "$maxretry" ]; then
            log_info "Fail2ban SSH jail already configured with desired values"
            # Still enable and start if not running
            if ! systemctl is-active --quiet fail2ban 2>/dev/null && \
               ! service fail2ban status >/dev/null 2>&1; then
                systemctl enable --now fail2ban 2>/dev/null || service fail2ban start 2>/dev/null || true
            fi
            state_mark "fail2ban" "completed"
            return 0
        fi
    fi
    
    # Create jail.local configuration
    {
        echo "[DEFAULT]"
        echo "# Ban hosts for one hour:"
        echo "bantime = $ban_time"
        echo ""
        echo "# Override /etc/fail2ban/jail.d/00-firewalld.conf:"
        echo "banaction = iptables-multiport"
        echo ""
        echo "# Email notifications:"
        if [ -n "$email_action" ]; then
            echo "action = $(echo "$email_action" | sed 's/_$//')"
            echo "mta = sendmail"
            echo "dest = $dest_email"
            echo "sender = $sender_email"
            echo "sendername = $sendername"
        else
            echo "action = iptables-multiport"
        fi
        echo ""
        echo ""
        echo "[sshd]"
        echo "enabled = true"
        echo "filter = sshd"
        echo "action = $(echo "$email_action" | sed 's/_$//')iptables-multiport"
        echo "logpath = %(sshd_log)s"
        echo "maxretry = $maxretry"
        echo "findtime = $findtime"
        echo "bantime = $ban_time"
        echo ""
        echo "# Additional common jails"
        echo ""
        echo "[sshd-ddos]"
        echo "enabled = true"
        echo "filter = sshddos"
        echo "action = iptables-multiport name=sshd-ddos port=$ssh_port"
        echo "logpath = %(sshd_log)s"
        echo "maxretry = 5"
        echo "findtime = $findtime"
        echo "bantime = $ban_time"
        echo ""
        echo "[recidive]"
        echo "enabled = true"
        echo "filter = recidive"
        echo "logpath = /var/log/fail2ban.log"
        echo "action = iptables-all"
        echo "bantime = 604800  ; 1 week"
        echo "findtime = 86400  ; 1 day"
        echo "maxretry = 5"
    } > /etc/fail2ban/jail.local
    
    # Create jail.d directory if it doesn't exist
    mkdir -p /etc/fail2ban/jail.d
    
    # Disable unnecessary jails to reduce false positives
    {
        echo "[sshd]"
        echo "enabled = true"
        echo ""
        echo "[ddos]"
        echo "enabled = false"
        echo ""
        echo "[nginx-http-auth]"
        echo "enabled = false"
        echo ""
        echo "[nginx-limit-req]"
        echo "enabled = false"
        echo ""
        echo "[nginx-badbots]"
        echo "enabled = false"
    } > /etc/fail2ban/jail.d/00-disable-unsafe.conf
    
    # Restart fail2ban service
    log_info "Starting Fail2ban service..."
    if systemctl daemon-reload 2>/dev/null; then
        systemctl enable --now fail2ban
    else
        service fail2ban restart 2>/dev/null || true
    fi
    
    # Verify fail2ban is running
    sleep 2
    if fail2ban-client status >/dev/null 2>&1; then
        # Get status
        local status
        status=$(fail2ban-client status 2>/dev/null || echo "Status unknown")
        
        log_info "Fail2ban started successfully"
        log_info "Status: $status"
        
        # Show jail status
        echo ""
        echo "Fail2ban Status:"
        echo "----------------"
        fail2ban-client status 2>/dev/null || true
        echo ""
        echo "SSH Jail Status:"
        echo "----------------"
        fail2ban-client status sshd 2>/dev/null || true
        echo ""
        
        audit "FAIL2BAN_CONFIGURED" "ban_time=$ban_time findtime=$findtime maxretry=$maxretry ssh_port=$ssh_port email_enabled=${email_action:+yes}"
        state_mark "fail2ban" "completed"
    else
        log_error "Failed to start Fail2ban service"
        # Try to get error logs
        journalctl -u fail2ban --no-pager -n 20 2>/dev/null || true
        return 1
    fi
    
    log_info "Fail2ban installation and configuration completed"
}

# Allow sourcing without execution
if [ "${0##*/}" != "fail2ban.sh" ] && [ "${0##*/}" != "bash" ] && [ "${0##*/}" != "sh" ]; then
    return 0
fi

# If executed directly, run the main function
fail2ban_main "$@"