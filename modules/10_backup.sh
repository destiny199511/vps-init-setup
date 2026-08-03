#!/bin/sh
#
# Backup Module - Configure automated backup system
#

backup_info() {
    echo "Configure automated backup system for critical data"
}

backup_prerequisites() {
    return 0
}

backup_main() {
    log_info "Starting backup configuration..."
    
    # Determine backup configuration
    local backup_enabled backup_schedule backup_directories backup_retention
    local backup_compression backup_encryption backup_destination
    
    if [ "${NON_INTERACTIVE:-false}" = "true" ]; then
        backup_enabled="${BACKUP_ENABLED:-false}"
        backup_schedule="${BACKUP_SCHEDULE:-0 2 * * *}"  # Daily at 2 AM
        backup_directories="${BACKUP_DIRECTORIES:-/etc /var/www /home}"
        backup_retention="${BACKUP_RETENTION:-30}"  # Days
        backup_compression="${BACKUP_COMPRESSION:-gzip}"
        backup_encryption="${BACKUP_ENCRYPTION:-false}"
        backup_destination="${BACKUP_DESTINATION:-/backups}"
    else
        echo "Backup Configuration:"
        echo "---------------------"
        
        # Enable backups
        printf '\033[1;33m'
        read -r -p "Enable automated backups? [y/N] " choice
        printf '\033[0m\n'
        case "$choice" in
            y|Y|yes|Yes) backup_enabled=true ;;
            *) backup_enabled=false ;;
        esac
        
        if [ "$backup_enabled" = "true" ]; then
            # What to backup
            echo "Directories to backup (space-separated):"
            echo "Common: /etc /home /var/www /var/lib/mysql /root"
            read -r -p "Enter directories: " backup_directories
            [ -z "$backup_directories" ] && backup_directories="/etc /home"
            
            # Backup schedule
            echo ""
            echo "Backup schedule (cron format):"
            echo "Examples:"
            echo "  0 2 * * *     Daily at 2 AM"
            echo "  0 2 * * 0     Weekly on Sunday at 2 AM"
            echo "  0 0 1 * *     Monthly on 1st at midnight"
            read -r -p "Enter cron schedule [0 2 * * *]: " backup_schedule
            [ -z "$backup_schedule" ] && backup_schedule="0 2 * * *"
            
            # Retention
            read -r -p "Retention period (days) [30]: " choice
            [ -z "$choice" ] && choice=30
            backup_retention="$choice"
            
            # Compression
            echo ""
            echo "Compression options:"
            echo "  gzip   - Good compression, fast"
            echo "  bzip2  - Better compression, slower"
            echo "  xz     - Best compression, slowest"
            echo "  none   - No compression"
            read -r -p "Compression type [gzip]: " choice
            [ -z "$choice" ] && choice="gzip"
            backup_compression="$choice"
            
            # Encryption
            read -r -p "Enable encryption? [y/N] (requires gpg) " choice
            case "$choice" in
                y|Y|yes|Yes) backup_encryption=true ;;
                *) backup_encryption=false ;;
            esac
            
            # Destination
            echo ""
            echo "Backup destination options:"
            echo "  Local directory: /backups"
            echo "  Remote (rsync): user@host:/path/to/backups"
            echo "  Cloud: Would need additional configuration"
            read -r -p "Backup destination [/backups]: " choice
            [ -z "$choice" ] && choice="/backups"
            backup_destination="$choice"
        fi
    fi
    
    # If backups disabled, just check if we should remove existing setup
    if [ "$backup_enabled" = "false" ]; then
        # Check if backup system is already configured
        if [ -f "/etc/cron.d/backup-system" ] || [ -f "/var/spool/cron/root" ] && grep -q "backup" /var/spool/cron/root; then
            if [ "${NON_INTERACTIVE:-false}" = "false" ]; then
                read -r -p "Backup system appears configured. Remove it? [y/N] " choice
                case "$choice" in
                    y|Y|yes|Yes) ;;
                    *) 
                        log_info "Backup configuration skipped"
                        state_mark "backup" "completed"
                        return 0
                        ;;
                esac
            else
                # In non-interactive mode, we'll remove if FORCE_CONFIGURE is true
                if [ "${FORCE_CONFIGURE:-false}" = "true" ]; then
                    :
                else
                    log_info "Backup disabled, skipping configuration"
                    state_mark "backup" "completed"
                    return 0
                fi
            fi
        else
            log_info "Backup system not configured and disabled - skipping"
            state_mark "backup" "completed"
            return 0
        fi
    fi
    
    # Validate inputs
    if [ -z "$backup_directories" ]; then
        log_error "No backup directories specified"
        return 1
    fi
    
    # Validate cron syntax (basic)
    if ! echo "$backup_schedule" | grep -qE '^(\*|[0-9]+(\/[0-9]+)?\s+){4}\*|[0-9]+(\/[0-9]+)?$'; then
        log_warn "Cron schedule format may be incorrect: $backup_schedule"
        if [ "${FORCE:-false}" != "true" ] && [ "${SKIP_CONFIRMATIONS:-false}" = "false" ]; then
            read -r -p "Continue anyway? [y/N] " choice
            case "$choice" in
                y|Y|yes|Yes) ;;
                *) return 1 ;;
            esac
        fi
    fi
    
    # Create backup directory
    if [ ! -d "$backup_destination" ]; then
        log_info "Creating backup directory: $backup_destination"
        mkdir -p "$backup_destination"
        chmod 700 "$backup_destination"  # Restrict access
    fi
    
    # Install required packages
    local required_packages="cron"
    if [ "$backup_compression" != "none" ]; then
        required_packages="$required_packages gzip"
        if [ "$backup_compression" = "bzip2" ]; then
            required_packages="$required_packages bzip2"
        elif [ "$backup_compression" = "xz" ]; then
            required_packages="$required_packages xz-utils"
        fi
    fi
    
    if [ "$backup_encryption" = "true" ]; then
        required_packages="$required_packages gnupg"
        # Check if GPG key exists, otherwise note that user needs to set it up
        if ! gpg --list-keys "backup-key" >/dev/null 2>&1; then
            log_warn "No GPG key found for backup encryption. You'll need to create one:"
            log_warn "  gpg --gen-key"
            log_warn "Then export it and specify in backup script."
        fi
    fi
    
    # Install packages
    for pkg in $required_packages; do
        install_package "$pkg"
    done
    
    # Create backup script
    local backup_script="/usr/local/sbin/backup-system.sh"
    
    {
        echo "#!/bin/bash"
        echo "# Automated backup script - Generated by VPS Auto-Setup"
        echo "# Generated: $(date)"
        echo ""
        echo "set -euo pipefail"
        echo ""
        echo "# Configuration"
        echo "BACKUP_DIR=\"$backup_destination\""
        echo "SOURCES=\"$backup_directories\""
        echo "RETENTION_DAYS=$backup_retention"
        echo "COMPRESSION=\"$backup_compression\""
        echo "ENCRYPTION=\"$backup_encryption\""
        echo ""
        echo "# Colors for output"
        echo "RED='\\033[0;31m'"
        echo "GREEN='\\033[0;32m'"
        echo "YELLOW='\\033[1;33m'"
        echo "NC='\\033[0m' # No Color"
        echo ""
        echo "log() {"
        echo "    echo -e \"[\$(date '+%Y-%m-%d %H:%M:%S')] $1\""
        echo "}"
        echo ""
        echo "error_exit() {"
        echo "    log \"${RED}ERROR: $1${NC}\" >&2"
        echo "    exit 1"
        echo "}"
        echo ""
        echo "create_backup() {"
        echo "    local timestamp=\"\$(date +%Y%m%d_%H%M%S)\""
        echo "    local hostname=\"\$(hostname)\""
        echo "    local backup_file=\"${backup_dir}/backup_\${hostname}_\${timestamp}.tar\""
        echo ""
        echo "    log \"Starting backup of:\${SOURCES}\""
        echo ""
        echo "    # Create tar archive"
        echo "    if ! tar -cf \"\$backup_file\" \$SOURCES 2>/dev/null; then"
        echo "        error_exit \"Failed to create tar archive\""
        echo "    fi"
        echo ""
        echo "    # Compress if requested"
        echo "    case \"\$COMPRESSION\" in"
        echo "        gzip)"
        echo "            if ! gzip \"\$backup_file\"; then"
        echo "                error_exit \"Failed to compress backup with gzip\""
        echo "            fi"
        echo "            backup_file=\"\${backup_file}.gz\""
        echo "            ;;"
        echo "        bzip2)"
        echo "            if ! bzip2 \"\$backup_file\"; then"
        echo "                error_exit \"Failed to compress backup with bzip2\""
        echo "            fi"
        echo "            backup_file=\"\${backup_file}.bz2\""
        echo "            ;;"
        echo "        xz)"
        echo "            if ! xz \"\$backup_file\"; then"
        echo "                error_exit \"Failed to compress backup with xz\""
        echo "            fi"
        echo "            backup_file=\"\${backup_file}.xz\""
        echo "            ;;"
        echo "        none)"
        echo "            # No compression"
        echo "            ;;"
        echo "        *)"
        echo "            error_exit \"Unknown compression type: \$COMPRESSION\""
        echo "            ;;"
        echo "    esac"
        echo ""
        echo "    # Encrypt if requested"
        echo "    if [ \"\$ENCRYPTION\" = \"true\" ]; then"
        echo "        if ! gpg --encrypt --recipient \"backup-key\" \"\$backup_file\"; then"
        echo "            error_exit \"Failed to encrypt backup\""
        echo "        fi"
        echo "        # Remove unencrypted file"
        echo "        rm -f \"\$backup_file\""
        echo "        backup_file=\"\${backup_file}.gpg\""
        echo "    fi"
        echo ""
        echo "    log \"Backup completed: \$(basename \"\$backup_file\")\""
        echo "    log \"Size: \$(du -h \"\$backup_file\" | cut -f1)\""
        echo ""
        echo "    # Cleanup old backups"
        echo "    cleanup_old_backups"
        echo ""
        echo "    return 0"
        echo "}"
        echo ""
        echo "cleanup_old_backups() {"
        echo "    log \"Cleaning up backups older than \$RETENTION_DAYS days\""
        echo "    "
        echo "    # Find and remove old backup files"
        echo "    find \"\$BACKUP_DIR\" -type f \\( -name \"backup_*.tar.gz\" -o -name \"backup_*.tar.bz2\" -o -name \"backup_*.tar.xz\" -o -name \"backup_*.tar\" -o -name \"backup_*.tar.gpg\" -o -name \"backup_*.tar.gz.gpg\" -o -name \"backup_*.tar.bz2.gpg\" -o -name \"backup_*.tar.xz.gpg\" \\) -mtime +\$RETENTION_DAYS -delete"
        echo "    "
        echo "    log \"Cleanup completed\""
        echo "}"
        echo ""
        echo "# Main execution"
        echo "log \"Backup script started\""
        echo ""
        echo "# Create backup directory if it doesn't exist"
        echo "mkdir -p \"\$BACKUP_DIR\""
        echo ""
        echo "# Run backup"
        echo "create_backup"
        echo ""
        echo "log \"Backup script completed successfully\""
    } > "$backup_script"
    
    chmod +x "$backup_script"
    chmod 700 "$backup_script"  # Only root can read/execute
    
    # Create cron job
    local cron_file="/etc/cron.d/backup-system"
    {
        echo "# Automated backup job - Generated by VPS Auto-Setup"
        echo "# Generated: $(date)"
        echo ""
        # Format: minute hour day month dayofweek user command
        echo "$backup_schedule root $backup_script >> /var/log/backup.log 2>&1"
        echo ""
        # Also create a logrotate rule for the backup log
    } > "$cron_file"
    
    # Create logrotate config for backup logs
    local logrotate_file="/etc/logrotate.d/backup-system"
    {
        echo "/var/log/backup.log {"
        echo "    weekly"
        echo "    rotate 4"
        echo "    compress"
        echo "    delaycompress"
        echo "    missingok"
        echo "    notifempty"
        echo "}"
    } > "$logrotate_file"
    
    # Ensure cron is running
    systemctl enable --now cron 2>/dev/null || service cron start 2>/dev/null || true
    
    # Create initial backup if requested (non-interactive)
    if [ "${NON_INTERACTIVE:-false}" = "true" ] && [ "${BACKUP_RUN_INITIAL:-false}" = "true" ]; then
        log_info "Running initial backup..."
        "$backup_script" || log_warn "Initial backup failed - this may be expected if configuring for the first time"
    fi
    
    # Mark completion
    state_mark "backup" "completed"
    log_info "Backup configuration completed successfully"
    log_info "Backup script: $backup_script"
    log_info "Cron schedule: $cron_file"
    log_info "Backup destination: $backup_destination"
    if [ "$backup_enabled" = "true" ]; then
        log_info "Next backup scheduled according to: $backup_schedule"
    fi
}

# Allow sourcing without execution
if [ "${0##*/}" != "backup.sh" ] && [ "${0##*/}" != "bash" ] && [ "${0##*/}" != "sh" ]; then
    return 0
fi

# If executed directly, run the main function
backup_main "$@"