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
    
    # Get every effective SSH port, including a legacy port kept during migration.
    local ssh_ports ssh_port
    ssh_ports=$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' | awk '!seen[$0]++' | paste -sd ',' -)
    ssh_ports="${ssh_ports:-${SSH_PORT:-22}}"
    ssh_port="${ssh_ports%%,*}"

    local firewall_type ban_action ban_action_allports
    firewall_type="$(detect_firewall)"
    case "$firewall_type" in
        ufw)
            ban_action="ufw"
            ban_action_allports="ufw"
            ;;
        firewalld)
            ban_action="firewallcmd-ipset"
            ban_action_allports="firewallcmd-ipset"
            ;;
        nftables)
            ban_action="nftables-multiport"
            ban_action_allports="nftables-allports"
            ;;
        *)
            ban_action="iptables-multiport"
            ban_action_allports="iptables-allports"
            ;;
    esac
    # Fall back when the preferred all-ports action is not packaged.
    if [ ! -f "/etc/fail2ban/action.d/${ban_action_allports}.conf" ]; then
        ban_action_allports="$ban_action"
    fi

    local ignore_ips="${FAIL2BAN_IGNOREIP:-127.0.0.1/8 ::1}"
    local detected_client_ip=""
    local management_ip=""
    if [ -n "${SSH_CONNECTION:-}" ]; then
        detected_client_ip="${SSH_CONNECTION%% *}"
    elif [ -n "${SSH_CLIENT:-}" ]; then
        detected_client_ip="${SSH_CLIENT%% *}"
    fi
    if [ -n "$detected_client_ip" ]; then
        management_ip="$detected_client_ip"
        case " $ignore_ips " in
            *" $detected_client_ip "*) ;;
            *) ignore_ips="$ignore_ips $detected_client_ip" ;;
        esac
    fi
    for detected_client_ip in $(ss -tnH 2>/dev/null | awk -v ports="$ssh_ports" '
        BEGIN { count = split(ports, wanted, ",") }
        $1 == "ESTAB" {
            local_port = $4
            sub(/^.*:/, "", local_port)
            for (i = 1; i <= count; i++) {
                if (local_port == wanted[i]) {
                    peer = $5
                    sub(/^\[/, "", peer)
                    sub(/\]:[0-9]+$/, "", peer)
                    sub(/:[0-9]+$/, "", peer)
                    print peer
                }
            }
        }' | sort -u); do
        case " $ignore_ips " in
            *" $detected_client_ip "*) ;;
            *) ignore_ips="$ignore_ips $detected_client_ip" ;;
        esac
    done
    log_info "Fail2ban SSH ports: $ssh_ports; ignore IPs: $ignore_ips"

    # Match the sshd process directly; unit names differ across Ubuntu builds
    # and combining two _SYSTEMD_UNIT predicates creates an impossible match.
    local ssh_journal_match='_COMM=sshd'
    
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
                email_action=""
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
           grep -q "port.*$ssh_port" /etc/fail2ban/jail.local && \
           grep -q "^journalmatch = $ssh_journal_match$" /etc/fail2ban/jail.local && \
           grep -q "^banaction = $ban_action$" /etc/fail2ban/jail.local && \
           grep -q "^action = $ban_action$" /etc/fail2ban/jail.local && \
           { [ -z "$management_ip" ] || awk -v ip="$management_ip" '$1 == "ignoreip" { for (i = 3; i <= NF; i++) if ($i == ip) found = 1 } END { exit !found }' /etc/fail2ban/jail.local; }; then
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
            if [ -n "$management_ip" ] && command -v fail2ban-client >/dev/null 2>&1; then
                fail2ban-client set sshd unbanip "$management_ip" >/dev/null 2>&1 || true
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
        echo "ignoreip = $ignore_ips"
        echo "backend = systemd"
        echo ""
        echo "# Use the action matching the active firewall backend: $firewall_type"
        echo "banaction = $ban_action"
        echo "banaction_allports = $ban_action_allports"
        echo ""
        echo "# Email notifications:"
        if [ -n "$email_action" ]; then
            echo "action = $email_action"
            echo "mta = sendmail"
            echo "destemail = $dest_email"
            echo "sender = $sender_email"
            echo "sendername = $sendername"
        else
            echo "action = $ban_action"
        fi
        echo ""
        echo ""
        echo "[sshd]"
        echo "enabled = true"
        echo "filter = sshd"
        echo "port = $ssh_ports"
        echo "action = $ban_action"
        echo "backend = systemd"
        echo "journalmatch = $ssh_journal_match"
        echo "maxretry = $maxretry"
        echo "findtime = $findtime"
        echo "bantime = $ban_time"
        echo ""
        echo ""
        echo "[recidive]"
        echo "enabled = true"
        echo "filter = recidive"
        echo "logpath = /var/log/fail2ban.log"
        echo "backend = auto"
        echo "action = $ban_action_allports"
        echo "bantime = 604800"
        echo "findtime = 86400"
        echo "maxretry = 5"
    } > /etc/fail2ban/jail.local

    # recidive reads fail2ban's own logfile; ensure it exists before start.
    touch /var/log/fail2ban.log 2>/dev/null || true
    chmod 640 /var/log/fail2ban.log 2>/dev/null || true
    
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

    # Override distribution and legacy jail.d files with a late, managed file.
    {
        echo "[sshd]"
        echo "enabled = true"
        echo "filter = sshd"
        echo "port = $ssh_ports"
        echo "action = $ban_action"
        echo "backend = systemd"
        echo "journalmatch = $ssh_journal_match"
        echo "maxretry = $maxretry"
        echo "findtime = $findtime"
        echo "bantime = $ban_time"
    } > /etc/fail2ban/jail.d/99-vps-init-setup.conf
    
    # Validate before touching the running service; a bad jail must not take
    # down an otherwise usable security service.
    if ! fail2ban-client -t >/dev/null 2>&1; then
        log_error "Fail2ban configuration validation failed; keeping the previous service state"
        fail2ban-client -t 2>&1 | while read -r line; do
            log_error "Fail2ban config: $line"
        done
        return 1
    fi

    # Restart fail2ban service
    log_info "Starting Fail2ban service..."
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable fail2ban >/dev/null 2>&1 || true
        if ! systemctl restart fail2ban; then
            log_error "Failed to restart Fail2ban after configuration update"
            return 1
        fi
    else
        service fail2ban restart 2>/dev/null || return 1
    fi
    
    # Verify fail2ban is running
    sleep 2
    if fail2ban-client status >/dev/null 2>&1; then
        local runtime_journalmatch
        runtime_journalmatch="$(fail2ban-client get sshd journalmatch 2>/dev/null || true)"
        if ! printf '%s\n' "$runtime_journalmatch" | grep -Fq "$ssh_journal_match"; then
            log_error "Fail2ban sshd jail is not using the expected journalmatch: $runtime_journalmatch"
            fail2ban-client status sshd 2>/dev/null || true
            return 1
        fi
        if [ -n "$management_ip" ]; then
            fail2ban-client set sshd unbanip "$management_ip" >/dev/null 2>&1 || true
        fi
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