#!/bin/sh
#
# Locale and Timezone Module - Configure system locale and timezone
#

locale_timezone_info() {
    echo "Configure system locale and timezone"
}

locale_timezone_prerequisites() {
    return 0
}

locale_timezone_main() {
    log_info "Starting locale and timezone configuration..."
    
    # Get current settings
    local current_locale current_timezone
    current_locale=$(locale | grep LANG= | cut -d= -f2 | tr -d '"')
    current_timezone=""
    if command -v timedatectl >/dev/null 2>&1; then
        current_timezone=$(timedatectl show-timezone 2>/dev/null || true)
    fi
    [ -z "$current_timezone" ] && current_timezone=$(readlink -f /etc/localtime 2>/dev/null | sed 's#^.*/zoneinfo/##')
    [ -z "$current_timezone" ] && current_timezone=$(cat /etc/timezone 2>/dev/null || true)
    current_timezone="${current_timezone:-UTC}"
    
    log_info "Current locale: $current_locale"
    log_info "Current timezone: $current_timezone"
    
    # Determine target locale
    local target_locale
    
    if [ "${NON_INTERACTIVE:-false}" = "true" ]; then
        target_locale="${LOCALE:-${DEFAULT_LOCALE:-en_US.UTF-8}}"
    else
        printf '\033[1;33m'
        echo "Common locale options:"
        echo "  en_US.UTF-8    English (United States)"
        echo "  zh_CN.UTF-8    Chinese (China)"
        echo "  zh_TW.UTF-8    Chinese (Taiwan)"
        echo "  ja_JP.UTF-8    Japanese (Japan)"
        echo "  ko_KR.UTF-8    Korean (Korea)"
        echo "  fr_FR.UTF-8    French (France)"
        echo "  de_DE.UTF-8    German (Germany)"
        read -r -p "Enter locale (current: $current_locale): " target_locale
        printf '\033[0m\n'
        
        if [ -z "$target_locale" ]; then
            target_locale="$current_locale"
            log_info "Keeping current locale: $target_locale"
        fi
    fi
    
    # Validate locale format (basic check)
    if ! echo "$target_locale" | grep -qE '^[a-z]{2}_[A-Z]{2}\.(UTF-8|utf8)$'; then
        log_warn "Locale format may be incorrect: $target_locale"
        log_warn "Expected format: xx_XX.UTF-8 (e.g., en_US.UTF-8)"
        if [ "${FORCE:-false}" != "true" ] && [ "${SKIP_CONFIRMATIONS:-false}" = "false" ]; then
            read -r -p "Continue anyway? [y/N] " choice
            case "$choice" in
                [yY][eE][sS]|[yY]) ;;
                *) return 1 ;;
            esac
        fi
    fi
    
    # Determine target timezone
    local target_timezone
    
    if [ "${NON_INTERACTIVE:-false}" = "true" ]; then
        target_timezone="${TIMEZONE:-${DEFAULT_TIMEZONE:-UTC}}"
    else
        # Show common timezones
        printf '\033[1;33m'
        echo "Common timezone options:"
        echo "  UTC             Coordinated Universal Time"
        echo "  America/New_York Eastern Time (US & Canada)"
        echo "  America/Chicago Central Time (US & Canada)"
        echo "  America/Denver  Mountain Time (US & Canada)"
        echo "  America/Los_Angeles Pacific Time (US & Canada)"
        echo "  Europe/London   Greenwich Mean Time"
        echo "  Europe/Paris    Central European Time"
        echo "  Asia/Tokyo      Japan Standard Time"
        echo "  Asia/Shanghai   China Standard Time"
        echo "  Asia/Kolkata    India Standard Time"
        read -r -p "Enter timezone (current: $current_timezone): " target_timezone
        printf '\033[0m\n'
        
        if [ -z "$target_timezone" ]; then
            target_timezone="$current_timezone"
            log_info "Keeping current timezone: $target_timezone"
        fi
    fi
    
    # Validate timezone (check if it exists in zoneinfo)
    if [ -z "$target_timezone" ] || [ ! -f "/usr/share/zoneinfo/$target_timezone" ] && [ ! -f "/usr/share/zoneinfo/posix/$target_timezone" ]; then
        # Try to find it in subdirectories
        if ! find /usr/share/zoneinfo -name "$target_timezone" -type f 2>/dev/null | grep -q .; then
            log_error "Timezone not found: $target_timezone"
            log_error "Please check spelling or use a valid timezone from /usr/share/zoneinfo"
            return 1
        fi
    fi
    
    local changes_made=false
    
    # Configure locale
    if [ "$target_locale" != "$current_locale" ]; then
        log_info "Setting locale to: $target_locale"
        
        # Backup locale configuration
        local locale_backup
        locale_backup=$(backup_file "/etc/default/locale") || true
        locale_backup=$(backup_file "/etc/locale.conf") || true
        
        # Generate locale
        log_info "Generating locale: $target_locale"
        case "$(detect_package_manager)" in
            apt)
                # Ensure language packs exist for common non-C locales.
                case "$target_locale" in
                    zh_CN.UTF-8|zh_CN.utf8)
                        install_package language-pack-zh-hans 2>/dev/null || true
                        ;;
                    zh_TW.UTF-8|zh_TW.utf8)
                        install_package language-pack-zh-hant 2>/dev/null || true
                        ;;
                esac
                # Check if locale already generated
                if ! locale -a 2>/dev/null | grep -qiE "^${target_locale//./\\.}$|^${target_locale//UTF-8/utf8}$"; then
                    if ! locale-gen "$target_locale"; then
                        log_error "Failed to generate locale: $target_locale"
                        return 1
                    fi
                fi
                # update-locale writes a consistent /etc/default/locale without
                # forcing the current shell into a locale that is still loading.
                if command -v update-locale >/dev/null 2>&1; then
                    update-locale LANG="$target_locale" LC_ALL="$target_locale" LANGUAGE="$target_locale" 2>/dev/null || {
                        printf 'LANG=%s\nLANGUAGE=%s\nLC_ALL=%s\n' "$target_locale" "$target_locale" "$target_locale" > /etc/default/locale
                    }
                else
                    {
                        echo "LANG=$target_locale"
                        echo "LANGUAGE=$target_locale"
                        echo "LC_ALL=$target_locale"
                    } > /etc/default/locale
                fi
                ;;
            yum|dnf)
                if ! locale -a 2>/dev/null | grep -q "^$target_locale$"; then
                    log_warn "Locale generation not automatic on RHEL-based systems"
                    log_warn "You may need to install glibc-langpack-$(echo "$target_locale" | cut -d_ -f1 | tr '[:upper:]' '[:lower:]')"
                fi
                {
                    echo "LANG=$target_locale"
                    echo "LC_ALL=$target_locale"
                } > /etc/locale.conf
                ;;
            apk)
                # Alpine uses different approach
                if ! apk info | grep -q glibc; then
                    log_warn "Alpine Linux uses musl, locale handling is different"
                fi
                {
                    echo "LANG=$target_locale"
                } > /etc/env.d/02locale
                ;;
            *)
                log_warn "Locale configuration not fully automated for this distribution"
                {
                    echo "LANG=$target_locale"
                    echo "LC_ALL=$target_locale"
                } > /etc/default/locale
                ;;
        esac
        
        # Export for current session only when the locale is actually available.
        if locale -a 2>/dev/null | grep -qiE "^${target_locale//./\\.}$|^${target_locale//UTF-8/utf8}$"; then
            export LANG="$target_locale"
            export LC_ALL="$target_locale"
        else
            log_warn "Locale $target_locale written to config but not yet active in this shell"
            export LANG="$target_locale"
            unset LC_ALL 2>/dev/null || true
        fi
        
        changes_made=true
        audit "LOCALE_CHANGED" "from=$current_locale to=$target_locale"
    else
        log_info "Locale already set to $target_locale, skipping"
    fi
    
    # Configure timezone
    if [ "$target_timezone" != "$current_timezone" ]; then
        log_info "Setting timezone to: $target_timezone"
        
        # Backup timezone configuration
        local tz_backup
        tz_backup=$(backup_file "/etc/timezone") || true
        tz_backup=$(backup_file "/etc/localtime") || true
        
        # Set timezone
        case "$(detect_init_system)" in
            systemd)
                if ! timedatectl set-timezone "$target_timezone"; then
                    log_warn "timedatectl unavailable, falling back to /etc/localtime"
                    ln -sfn "/usr/share/zoneinfo/$target_timezone" /etc/localtime
                    printf '%s\n' "$target_timezone" > /etc/timezone
                fi
                ;;
            *)
                # Traditional method
                cp -p "/usr/share/zoneinfo/$target_timezone" /etc/localtime
                echo "$target_timezone" > /etc/timezone
                ;;
        esac
        
        # Verify the change
        local new_timezone
        new_timezone=""
        if command -v timedatectl >/dev/null 2>&1; then
            new_timezone=$(timedatectl show-timezone 2>/dev/null || true)
        fi
        [ -z "$new_timezone" ] && new_timezone=$(readlink -f /etc/localtime 2>/dev/null | sed 's#^.*/zoneinfo/##')
        [ -z "$new_timezone" ] && new_timezone=$(cat /etc/timezone 2>/dev/null || true)
        if [ "$new_timezone" = "$target_timezone" ]; then
            log_info "Timezone successfully set to: $new_timezone"
            changes_made=true
            audit "TIMEZONE_CHANGED" "from=$current_timezone to=$target_timezone"
        else
            log_error "Failed to set timezone. Current: $new_timezone, Expected: $target_timezone"
            
            # Attempt rollback
            if [ -n "$tz_backup" ] && [ -f "$tz_backup" ]; then
                if [ -f "/etc/localtime" ]; then
                    cp -p "$tz_backup" /etc/localtime
                fi
                if [ -f "/etc/timezone" ]; then
                    cp -p "$tz_backup" /etc/timezone
                fi
                log_info "Rolled back timezone configuration"
            fi
            
            return 1
        fi
    else
        log_info "Timezone already set to $target_timezone, skipping"
    fi
    
    # Apply locale changes to current session
    if [ "$changes_made" = "true" ]; then
        # Re-source locale settings
        if [ -f /etc/default/locale ]; then
            # shellcheck disable=SC1091
            . /etc/default/locale
            export LANG LC_ALL
        fi
        
        log_info "Locale and timezone configuration completed"
        state_mark "locale_timezone" "completed"
    else
        log_info "No changes needed for locale or timezone"
        state_mark "locale_timezone" "completed"
    fi
}

# Allow sourcing without execution
if [ "${0##*/}" != "locale_timezone.sh" ] && [ "${0##*/}" != "bash" ] && [ "${0##*/}" != "sh" ]; then
    return 0
fi

# If executed directly, run the main function
locale_timezone_main "$@"