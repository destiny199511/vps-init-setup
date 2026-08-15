#!/bin/bash
#
# System Cleanup & Optimization Module
# - Create/resize swap
# - Remove snap (Ubuntu)
# - Clean package cache / old kernels
# - Disable unnecessary services
# - Clean systemd journal
# - Limit journald size
#

cleanup_info() {
    echo "System cleanup and optimization (swap, snap removal, cache/journal cleanup)"
}

cleanup_prerequisites() {
    # Must be root
    if [[ $EUID -ne 0 ]]; then
        log_error "cleanup module requires root privileges"
        return 1
    fi
    return 0
}

cleanup_main() {
    log_info "Starting system cleanup and optimization..."

    detect_os
    detect_pkg_manager

    local ram_mb swap_mb

    # ── 1. Swap 创建/调整 ──────────────────────────────────────

    local enable_swap="${ENABLE_SWAP:-true}"
    local swap_size="${SWAP_SIZE:-}"
    local swap_file="${SWAP_FILE:-/swapfile}"

    if [[ "$enable_swap" != "true" ]]; then
        log_info "Swap creation disabled (ENABLE_SWAP=false), skipping"
    else
        ram_mb=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
        swap_mb=$(awk '/SwapTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)

        log_info "Current RAM: ${ram_mb}MB, Swap: ${swap_mb}MB"

        if [[ $swap_mb -gt 0 ]]; then
            log_info "Swap already exists (${swap_mb}MB), skipping creation"
        else
            # Auto-calculate swap size if not specified
            if [[ -z "$swap_size" ]]; then
                if [[ $ram_mb -le 2048 ]]; then
                    swap_size="2G"
                elif [[ $ram_mb -le 8192 ]]; then
                    swap_size="4G"
                else
                    swap_size="8G"
                fi
            fi

            log_info "Creating swap file: ${swap_file} (${swap_size})"

            # Check available disk space
            local avail_mb
            avail_mb=$(df -m / | awk 'NR==2 {print $4}')
            local swap_unit="${swap_size: -1}"
            local swap_num="${swap_size%[KMGkmg]}"
            local swap_target_mb=2048
            case "${swap_unit^^}" in
                G) swap_target_mb=$((swap_num * 1024)) ;;
                M) swap_target_mb=$((swap_num)) ;;
                K) swap_target_mb=$(( (swap_num + 1023) / 1024 )) ;;
                *) [[ "$swap_size" =~ ^[0-9]+$ ]] && swap_target_mb=$((swap_size / 1024 / 1024)) || swap_target_mb=2048 ;;
            esac

            if [[ -n "$avail_mb" ]] && [[ $avail_mb -lt $swap_target_mb ]]; then
                log_error "Insufficient disk space for swap (${avail_mb}MB available, ${swap_size} needed)"
            else
                # Create swap file
                if fallocate -l "$swap_size" "$swap_file" 2>/dev/null; then
                    :
                else
                    # fallocate may not work on some filesystems, fall back to dd
                    log_warn "fallocate failed, using dd (slower)..."
                    dd if=/dev/zero of="$swap_file" bs=1M count="$swap_target_mb" status=progress
                fi

                chmod 600 "$swap_file"
                if mkswap "$swap_file" 2>/dev/null; then
                    if swapon "$swap_file" 2>/dev/null; then
                        log_info "Swap activated: ${swap_file} (${swap_size})"

                        # Add to fstab for persistence
                        if ! grep -q "$swap_file" /etc/fstab 2>/dev/null; then
                            backup_file /etc/fstab
                            echo "$swap_file none swap sw 0 0" >> /etc/fstab
                            audit "SWAP_CREATE" "${swap_file} ${swap_size}"
                            log_info "Swap added to /etc/fstab for persistence"
                        fi

                        # Optimize swappiness (lower = less swap usage, better for VPS)
                        local swappiness="${SWAPPINESS:-10}"
                        local vfs_cache_pressure="${VFS_CACHE_PRESSURE:-50}"
                        sysctl -w vm.swappiness="$swappiness" 2>/dev/null || true
                        sysctl -w vm.vfs_cache_pressure="$vfs_cache_pressure" 2>/dev/null || true

                        # Persist sysctl settings
                        if [[ -d /etc/sysctl.d ]]; then
                            cat > /etc/sysctl.d/99-swap.conf << EOF
vm.swappiness = $swappiness
vm.vfs_cache_pressure = $vfs_cache_pressure
EOF
                            audit "SYSCTL_SET" "vm.swappiness=$swappiness vm.vfs_cache_pressure=$vfs_cache_pressure"
                            log_info "Swappiness set to ${swappiness}, vfs_cache_pressure set to ${vfs_cache_pressure}"
                        fi
                    else
                        log_error "Failed to enable swap (swapon failed)"
                        rm -f "$swap_file"
                    fi
                else
                    log_error "Failed to create swap (mkswap failed)"
                    rm -f "$swap_file"
                fi
            fi
        fi
    fi

    # ── 2. 卸载 snap (Ubuntu) ───────────────────────────────────

    local remove_snap="${REMOVE_SNAP:-true}"

    if [[ "$remove_snap" != "true" ]]; then
        log_info "Snap removal disabled (REMOVE_SNAP=false), skipping"
    elif [[ "$OS_ID" != "ubuntu" ]] && [[ "$OS_ID" != "ubuntu-core" ]]; then
        log_info "Snap not found (OS: ${OS_ID}), skipping snap removal"
    elif ! command_exists snap; then
        log_info "snap command not installed, skipping snap removal"
    else
        log_info "Removing snap and snap-related packages..."

        # Remove all snap packages
        if snap list 2>/dev/null | tail -n +2 | awk '{print $1}'; then
            local snap_pkgs
            snap_pkgs=$(snap list 2>/dev/null | tail -n +2 | awk '{print $1}')
            for pkg in $snap_pkgs; do
                log_info "Removing snap package: $pkg"
                snap remove --purge "$pkg" 2>/dev/null || true
            done
        fi

        # Stop and disable snap services
        for svc in snapd snapd.socket snapd.seeded.service; do
            systemctl stop "$svc" 2>/dev/null || true
            systemctl disable "$svc" 2>/dev/null || true
        done

        # Purge snapd package
        remove_pkg snapd

        # Remove snap directories
        for dir in /snap /var/snap /var/lib/snapd /var/cache/snapd /usr/lib/snapd; do
            if [[ -d "$dir" ]]; then
                rm -rf "$dir" 2>/dev/null && log_info "Removed directory: $dir"
            fi
        done

        # Prevent snap from being reinstalled by apt
        if [[ -d /etc/apt/preferences.d ]]; then
            cat > /etc/apt/preferences.d/nosnap.pref << 'EOF'
Package: snapd
Pin: release *
Pin-Priority: -1
EOF
            log_info "Created apt pin to prevent snap reinstallation"
        fi

        audit "SNAP_REMOVE" "snapd and all snap packages removed"
        log_info "Snap removal completed"
    fi

    # ── 3. 清理包管理器缓存 ─────────────────────────────────────

    local clean_pkg_cache="${CLEAN_PKG_CACHE:-true}"

    if [[ "$clean_pkg_cache" != "true" ]]; then
        log_info "Package cache cleanup disabled (CLEAN_PKG_CACHE=false), skipping"
    else
        log_info "Cleaning package manager cache..."
        case "$PKG_MGR" in
            apt|apt-get)
                # Clean package caches only. Do not run unrestricted autoremove on
                # cloud images: it can remove kernel headers/microcode accessories
                # that are still useful for AWS/GCP guests.
                apt-get autoclean -y 2>/dev/null || true
                apt-get clean 2>/dev/null || true
                # Remove only concrete old kernel images. Never purge meta packages
                # such as linux-image-aws / linux-image-generic which reinstall
                # the latest kernel package and can break cloud images.
                local current_kernel
                current_kernel=$(uname -r)
                local old_kernels
                old_kernels=$(dpkg -l 'linux-image-*' 2>/dev/null | awk '/^ii/ {print $2}' | \
                    grep -E '^linux-image-[0-9]' | \
                    grep -vF "$current_kernel" | \
                    grep -Ev 'linux-image-(aws|generic|virtual|cloud|oem|lowlatency|gke|gcp|azure|extra|unsigned)' || true)
                if [ -n "$old_kernels" ]; then
                    for kernel in $old_kernels; do
                        log_info "Removing old kernel: $kernel"
                        apt-get purge -y "$kernel" 2>/dev/null || true
                    done
                    apt-get autoremove -y 2>/dev/null || true
                else
                    log_info "No obsolete concrete kernel images found to remove"
                fi
                # Clean apt lists
                rm -rf /var/lib/apt/lists/* 2>/dev/null || true
                log_info "APT cache cleaned, old kernels removed"
                ;;
            dnf|yum)
                "$PKG_MGR" autoremove -y 2>/dev/null || true
                "$PKG_MGR" clean all 2>/dev/null || true
                # Remove old kernels (keep current + 1)
                local current_kernel_rhel
                current_kernel_rhel=$(uname -r)
                if command_exists package-cleanup 2>/dev/null; then
                    package-cleanup --oldkernels --count=1 -y 2>/dev/null || true
                fi
                log_info "DNF/YUM cache cleaned"
                ;;
            apk)
                apk cache clean 2>/dev/null || true
                log_info "APK cache cleaned"
                ;;
            *)
                log_warn "Unknown package manager, skipping cache cleanup"
                ;;
        esac
        audit "PKG_CACHE_CLEAN" "$PKG_MGR cache cleaned"
    fi

    # ── 4. 清理 systemd journal ─────────────────────────────────

    local clean_journal="${CLEAN_JOURNAL:-true}"
    local journal_max_size="${JOURNAL_MAX_SIZE:-200M}"

    if [[ "$clean_journal" != "true" ]]; then
        log_info "Journal cleanup disabled (CLEAN_JOURNAL=false), skipping"
    elif ! command_exists journalctl 2>/dev/null; then
        log_info "journalctl not found, skipping journal cleanup"
    else
        log_info "Cleaning systemd journal (max: ${journal_max_size})..."

        # Vacuumjournal to target size
        journalctl --vacuum-size="$journal_max_size" 2>/dev/null || true

        # Also vacuum by time (keep last 7 days)
        journalctl --vacuum-time=7d 2>/dev/null || true

        # Configure journald to limit future growth
        if [[ -f /etc/systemd/journald.conf ]]; then
            backup_file /etc/systemd/journald.conf
            if grep -q "^SystemMaxUse=" /etc/systemd/journald.conf; then
                sed -i "s/^SystemMaxUse=.*/SystemMaxUse=$journal_max_size/" /etc/systemd/journald.conf
            else
                sed -i "s/^#SystemMaxUse=.*/SystemMaxUse=$journal_max_size/" /etc/systemd/journald.conf || \
                    echo "SystemMaxUse=$journal_max_size" >> /etc/systemd/journald.conf
            fi
            if grep -q "^MaxRetentionSec=" /etc/systemd/journald.conf; then
                sed -i 's/^MaxRetentionSec=.*/MaxRetentionSec=7day/' /etc/systemd/journald.conf
            else
                sed -i 's/^#MaxRetentionSec=.*/MaxRetentionSec=7day/' /etc/systemd/journald.conf || \
                    echo "MaxRetentionSec=7day" >> /etc/systemd/journald.conf
            fi
            systemctl restart systemd-journald 2>/dev/null || true
            audit "JOURNAL_CONFIG" "SystemMaxUse=$journal_max_size, MaxRetentionSec=7day"
            log_info "Journald configured: max ${journal_max_size}, retention 7 days"
        fi
    fi

    # ── 5. 禁用不必要的服务 ─────────────────────────────────────

    local disable_services="${DISABLE_SERVICES:-true}"

    if [[ "$disable_services" != "true" ]]; then
        log_info "Service disabling skipped (DISABLE_SERVICES=false)"
    else
        log_info "Disabling unnecessary services..."

        # List of commonly unnecessary services (safe to disable)
        local unnecessary_services=(
            "apt-daily-upgrade.timer"
            "apt-daily.timer"
            "motd-news.service"
            " snapd.service"
            "snapd.socket"
            "rsyslog.service"
            " ModemManager.service"
            "modemmanager.service"
            "fwupd.service"
        )

        for svc in "${unnecessary_services[@]}"; do
            # Trim leading whitespace
            svc=$(echo "$svc" | xargs)
            if systemctl is-enabled "$svc" 2>/dev/null | grep -q "enabled"; then
                systemctl disable "$svc" 2>/dev/null && log_info "Disabled: $svc"
                systemctl stop "$svc" 2>/dev/null || true
            fi
        done

        # Disable apport (Ubuntu crash reporter) — saves resources
        if [[ "$OS_ID" = "ubuntu" ]] && [[ -f /etc/default/apport ]]; then
            backup_file /etc/default/apport
            sed -i 's/enabled=1/enabled=0/' /etc/default/apport 2>/dev/null || true
            systemctl disable apport 2>/dev/null || true
            audit "DISABLE_APPORT" "apport crash reporter disabled"
            log_info "Disabled apport (crash reporter)"
        fi

        audit "DISABLE_SERVICES" "unnecessary services disabled"
    fi

    # ── 6. 清理临时文件和旧日志 ─────────────────────────────────

    local clean_temp="${CLEAN_TEMP:-true}"

    if [[ "$clean_temp" != "true" ]]; then
        log_info "Temp file cleanup disabled (CLEAN_TEMP=false), skipping"
    else
        log_info "Cleaning temporary files and old logs..."

        # Clean /tmp (only files older than 7 days, not /tmp itself)
        find /tmp -type f -mtime +7 -delete 2>/dev/null || true

        # Clean /var/tmp (only files older than 30 days)
        find /var/tmp -type f -mtime +30 -delete 2>/dev/null || true

        # Clean old log files in /var/log (only .gz and .1 files older than 30 days)
        find /var/log -name "*.gz" -mtime +30 -delete 2>/dev/null || true
        find /var/log -name "*.1" -mtime +30 -delete 2>/dev/null || true

        # Tru /var/log/journal if it exists (alternative journal storage)
        if [[ -d /var/log/journal ]]; then
            journalctl --vacuum-size="$journal_max_size" 2>/dev/null || true
        fi

        audit "TEMP_CLEAN" "temp files and old logs cleaned"
        log_info "Temporary files and old logs cleaned"
    fi

    # ── 7. 优化文件系统挂载参数 ─────────────────────────────────

    local optimize_fstab="${OPTIMIZE_FSTAB:-true}"

    if [[ "$optimize_fstab" != "true" ]]; then
        log_info "fstab optimization disabled (OPTIMIZE_FSTAB=false), skipping"
    elif [[ -f /etc/fstab ]]; then
        log_info "Optimizing filesystem mount options..."

        backup_file /etc/fstab

        local fstab_changed=false

        # Add noatime to non-root filesystems (reduces write I/O)
        if ! grep -q "noatime" /etc/fstab 2>/dev/null; then
            # Only modify non-root ext4/xfs partitions
            local fs_line
            fs_line=$(grep -v "^#" /etc/fstab | grep -E "ext[234]|xfs" | grep -v "/ " | grep -v "boot" | head -1)
            if [[ -n "$fs_line" ]]; then
                # This is a conservative optimization — we don't auto-modify fstab
                # because errors can make the system unbootable
                log_info "Found filesystems that could benefit from noatime"
                log_warn "fstab noatime optimization skipped (risky to auto-apply). Consider adding 'noatime' manually."
            fi
        fi

        # Enable TRIM for SSDs
        if [[ -f /etc/cron.weekly/fstrim ]] || systemctl is-enabled fstrim.timer 2>/dev/null | grep -q "enabled"; then
            log_info "TRIM already configured"
        else
            if command_exists fstrim 2>/dev/null; then
                # Check if root filesystem is on SSD
                if lsblk -d -o ROTA 2>/dev/null | grep -q "0"; then
                    systemctl enable fstrim.timer 2>/dev/null && \
                        systemctl start fstrim.timer 2>/dev/null && \
                        log_info "Enabled periodic TRIM (fstrim.timer)"
                fi
            fi
        fi

        audit "FSTAB_OPTIMIZE" "filesystem mount options reviewed"
    fi

    # ── 8. 显示清理结果摘要 ─────────────────────────────────────

    local after_ram after_swap after_disk
    after_ram=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)
    after_swap=$(awk '/SwapTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)
    after_disk=$(df -m / 2>/dev/null | awk 'NR==2 {print $4}')

    log_info "=== Cleanup Summary ==="
    log_info "  RAM: ${after_ram}MB"
    log_info "  Swap: ${after_swap}MB"
    log_info "  Available disk: ${after_disk}MB"
    log_info "System cleanup and optimization completed"
}
