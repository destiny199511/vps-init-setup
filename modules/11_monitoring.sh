#!/usr/bin/env bash
#
# Monitoring Module - Install and configure system monitoring tools
#

monitoring_info() {
    echo "Install and configure system monitoring tools"
}

monitoring_prerequisites() {
    return 0
}

monitoring_config_candidate() {
    local target="$1"
    local parent candidate
    parent="$(dirname "$target")"

    if [ -L "$target" ] || { [ -e "$target" ] && [ ! -f "$target" ]; }; then
        log_error "Monitoring configuration path is not a regular file: $target"
        return 1
    fi
    if ! backup_file "$target" >/dev/null; then
        log_error "Failed to back up monitoring configuration: $target"
        return 1
    fi
    mkdir -p "$parent" || {
        log_error "Failed to create monitoring configuration directory: $parent"
        return 1
    }
    candidate="$(mktemp "$parent/.$(basename "$target").XXXXXX")" || {
        log_error "Failed to create temporary monitoring configuration: $target"
        return 1
    }
    if [ -f "$target" ]; then
        if ! cp -p "$target" "$candidate"; then
            rm -f "$candidate"
            log_error "Failed to stage monitoring configuration: $target"
            return 1
        fi
    elif ! chmod 644 "$candidate"; then
        rm -f "$candidate"
        log_error "Failed to set monitoring configuration permissions: $target"
        return 1
    fi
    printf '%s\n' "$candidate"
}

monitoring_commit_config() {
    local candidate="$1"
    local target="$2"
    if ! mv -f "$candidate" "$target"; then
        rm -f "$candidate"
        log_error "Failed to install monitoring configuration: $target"
        return 1
    fi
}

monitoring_restore_service_config() {
    local target="$1"
    local service_name="$2"
    if ! restore_tracked_path "$target"; then
        log_error "Failed to restore monitoring configuration: $target"
        return 1
    fi
    if ! systemctl restart "$service_name" 2>/dev/null && \
       ! service "$service_name" restart 2>/dev/null; then
        log_error "Failed to restart $service_name with its restored configuration"
        return 1
    fi
}

monitoring_main() {
    log_info "Starting monitoring setup..."

    local tools_enabled netdata_enabled prometheus_node_enabled install_basic_tools
    tools_enabled=false
    netdata_enabled=false
    prometheus_node_enabled=false
    install_basic_tools=false

    if [ "${NON_INTERACTIVE:-false}" = "true" ]; then
        # Prefer wizard/config values over legacy MONITORING_* env names.
        if [ "${ENABLE_MONITORING:-false}" = "true" ] || [ "${MONITORING_ENABLED:-false}" = "true" ]; then
            tools_enabled=true
            install_basic_tools=true
        else
            tools_enabled=false
            install_basic_tools=false
        fi
        netdata_enabled="${MONITORING_NETDATA_ENABLED:-false}"
        if [ "${INSTALL_NODE_EXPORTER:-false}" = "true" ] || [ "${MONITORING_PROMETHEUS_NODE_ENABLED:-false}" = "true" ]; then
            prometheus_node_enabled=true
        else
            prometheus_node_enabled=false
        fi
    else
        read -r -p "Install monitoring tools? [Y/n] " choice
        case "$choice" in
            n|N|no|NO) tools_enabled=false ;;
            *) tools_enabled=true ;;
        esac

        if [ "$tools_enabled" = "true" ]; then
            read -r -p "Install basic CLI tools (htop, iotop, etc)? [Y/n] " choice
            case "$choice" in
                n|N|no|NO) install_basic_tools=false ;;
                *) install_basic_tools=true ;;
            esac

            read -r -p "Install Netdata (web dashboard)? [y/N] " choice
            case "$choice" in
                y|Y|yes|Yes) netdata_enabled=true ;;
                *) netdata_enabled=false ;;
            esac

            read -r -p "Install Prometheus Node Exporter? [y/N] " choice
            case "$choice" in
                y|Y|yes|Yes) prometheus_node_enabled=true ;;
                *) prometheus_node_enabled=false ;;
            esac
        fi
    fi

    if [ "$tools_enabled" = "false" ] && [ "$install_basic_tools" = "false" ] && \
       [ "$netdata_enabled" = "false" ] && [ "$prometheus_node_enabled" = "false" ]; then
        log_info "No monitoring components selected - skipping"
        state_mark "monitoring" "completed"
        return 0
    fi

    local changes_made=false

    # Install basic monitoring tools
    if [ "$install_basic_tools" = "true" ]; then
        log_info "Installing basic monitoring tools..."
        case "$(detect_package_manager)" in
            apt|deb) install_package htop iotop iftop ncdu sysstat dstat ;;
            yum|dnf|rpm) install_package htop iotop ncdu sysstat ;;
            apk) install_package htop iotop ncdu ;;
            *) log_info "Unsupported package manager - skipping basic tools" ;;
        esac

        if [ -f /etc/default/sysstat ]; then
            sed -i 's/ENABLED="false"/ENABLED="true"/' /etc/default/sysstat
            systemctl restart sysstat 2>/dev/null || service sysstat restart 2>/dev/null || true
        fi

        changes_made=true
        log_info "Basic monitoring tools installed"
        audit "MONITORING_BASIC_TOOLS_INSTALLED" "tools=htop,iotop,iftop,ncdu,sysstat,dstat"
    fi

    # Install Netdata
    if [ "$netdata_enabled" = "true" ]; then
        log_info "Installing Netdata..."
        if ! command -v netdata >/dev/null 2>&1; then
            case "$(detect_package_manager)" in
                apt|deb|dnf|yum|rpm|apk)
                    install_package netdata || {
                        log_error "Failed to install Netdata"
                        return 1
                    }
                    ;;
                *)
                    log_error "Netdata must be installed from a signed distribution package repository on this OS"
                    return 1
                    ;;
            esac
        fi

        # Secure Netdata: bind only to localhost to prevent public exposure
        local netdata_config_candidate
        netdata_config_candidate="$(monitoring_config_candidate /etc/netdata/netdata.conf)" || return 1
        if [ -f /etc/netdata/netdata.conf ]; then
            if grep -q "bind to =" "$netdata_config_candidate"; then
                sed -i 's/^[# ]*bind to =.*/bind to = 127.0.0.1/' "$netdata_config_candidate" || {
                    rm -f "$netdata_config_candidate"
                    log_error "Failed to secure Netdata bind address"
                    return 1
                }
            else
                printf "\n[web]\n    bind to = 127.0.0.1\n" >> "$netdata_config_candidate" || {
                    rm -f "$netdata_config_candidate"
                    log_error "Failed to secure Netdata bind address"
                    return 1
                }
            fi
        else
            cat <<'EOF' > "$netdata_config_candidate"
[web]
    bind to = 127.0.0.1
EOF
        fi
        monitoring_commit_config "$netdata_config_candidate" /etc/netdata/netdata.conf || return 1

        if ! systemctl enable --now netdata 2>/dev/null && ! service netdata start 2>/dev/null; then
            monitoring_restore_service_config /etc/netdata/netdata.conf netdata || true
            log_error "Netdata package installed but its service could not be started"
            return 1
        fi
        if ! systemctl restart netdata 2>/dev/null && ! service netdata restart 2>/dev/null; then
            monitoring_restore_service_config /etc/netdata/netdata.conf netdata || true
            log_error "Failed to restart Netdata with the secured configuration"
            return 1
        fi

        local netdata_active=false
        if systemctl is-active --quiet netdata 2>/dev/null || service netdata status >/dev/null 2>&1; then
            netdata_active=true
        fi
        if command -v netdata >/dev/null 2>&1 && [ "$netdata_active" = "true" ]; then
            log_info "Netdata installed and running (bound to 127.0.0.1:19999)"
            changes_made=true
            audit "MONITORING_NETDATA_INSTALLED" "port=19999 bind=127.0.0.1"
        else
            log_error "Netdata is not available after package installation"
            return 1
        fi
    fi

    # Install Prometheus Node Exporter
    if [ "$prometheus_node_enabled" = "true" ]; then
        log_info "Installing Prometheus Node Exporter..."
        case "$(detect_package_manager)" in
            apt|deb)
                install_package prometheus-node-exporter || {
                    log_error "Failed to install Prometheus Node Exporter"
                    return 1
                }
                local node_exporter_config_candidate
                node_exporter_config_candidate="$(monitoring_config_candidate /etc/default/prometheus-node-exporter)" || return 1
                if ! printf '%s\n' 'ARGS="--web.listen-address=127.0.0.1:9100"' > "$node_exporter_config_candidate"; then
                    rm -f "$node_exporter_config_candidate"
                    log_error "Failed to configure Node Exporter bind address"
                    return 1
                fi
                monitoring_commit_config "$node_exporter_config_candidate" /etc/default/prometheus-node-exporter || return 1
                if ! systemctl enable --now prometheus-node-exporter; then
                    monitoring_restore_service_config /etc/default/prometheus-node-exporter prometheus-node-exporter || true
                    log_error "Prometheus Node Exporter package installed but its service could not be started"
                    return 1
                fi
                if ! systemctl restart prometheus-node-exporter 2>/dev/null; then
                    monitoring_restore_service_config /etc/default/prometheus-node-exporter prometheus-node-exporter || true
                    log_error "Failed to restart Node Exporter with the secured configuration"
                    return 1
                fi
                ;;
            dnf|yum|rpm)
                install_package node_exporter || {
                    log_error "Failed to install Node Exporter"
                    return 1
                }
                local node_exporter_config_paths=()
                local node_exporter_candidates=()
                local config_path config_candidate candidate
                if [ -d /etc/default ]; then
                    config_path=/etc/default/node_exporter
                    config_candidate="$(monitoring_config_candidate "$config_path")" || return 1
                    if ! printf '%s\n' 'OPTIONS="--web.listen-address=127.0.0.1:9100"' > "$config_candidate"; then
                        rm -f "$config_candidate"
                        for candidate in "${node_exporter_candidates[@]}"; do rm -f "$candidate"; done
                        log_error "Failed to stage Node Exporter configuration: $config_path"
                        return 1
                    fi
                    node_exporter_config_paths+=("$config_path")
                    node_exporter_candidates+=("$config_candidate")
                fi
                if [ -d /etc/sysconfig ]; then
                    config_path=/etc/sysconfig/node_exporter
                    if ! config_candidate="$(monitoring_config_candidate "$config_path")"; then
                        for candidate in "${node_exporter_candidates[@]}"; do rm -f "$candidate"; done
                        return 1
                    fi
                    if ! printf '%s\n' 'OPTIONS="--web.listen-address=127.0.0.1:9100"' > "$config_candidate"; then
                        rm -f "$config_candidate"
                        for candidate in "${node_exporter_candidates[@]}"; do rm -f "$candidate"; done
                        log_error "Failed to stage Node Exporter configuration: $config_path"
                        return 1
                    fi
                    node_exporter_config_paths+=("$config_path")
                    node_exporter_candidates+=("$config_candidate")
                fi
                if [ "${#node_exporter_config_paths[@]}" -eq 0 ]; then
                    log_error "No supported Node Exporter configuration directory is available"
                    return 1
                fi
                local config_index
                for config_index in "${!node_exporter_config_paths[@]}"; do
                    if ! monitoring_commit_config "${node_exporter_candidates[$config_index]}" \
                        "${node_exporter_config_paths[$config_index]}"; then
                        for candidate in "${node_exporter_candidates[@]}"; do rm -f "$candidate"; done
                        for config_path in "${node_exporter_config_paths[@]}"; do
                            restore_tracked_path "$config_path" || \
                                log_error "Failed to restore Node Exporter configuration: $config_path"
                        done
                        return 1
                    fi
                done
                if ! systemctl enable --now node_exporter; then
                    for config_path in "${node_exporter_config_paths[@]}"; do
                        restore_tracked_path "$config_path" || \
                            log_error "Failed to restore Node Exporter configuration: $config_path"
                    done
                    log_error "Prometheus Node Exporter package installed but its service could not be started"
                    return 1
                fi
                if ! systemctl restart node_exporter 2>/dev/null; then
                    for config_path in "${node_exporter_config_paths[@]}"; do
                        restore_tracked_path "$config_path" || \
                            log_error "Failed to restore Node Exporter configuration: $config_path"
                    done
                    log_error "Failed to restart Node Exporter with the secured configuration"
                    return 1
                fi
                ;;
            *)
                log_error "Node Exporter must be installed from a signed distribution package repository on this OS"
                return 1
                ;;
        esac
        changes_made=true
        log_info "Prometheus Node Exporter installed on 127.0.0.1:9100"
        audit "MONITORING_PROMETHEUS_NODE_INSTALLED" "port=9100 bind=127.0.0.1"
    fi

    if [ "$changes_made" = "true" ]; then
        state_mark "monitoring" "completed"
    else
        state_mark "monitoring" "completed"
    fi

    log_info "Monitoring setup completed"
}

# Allow sourcing without execution
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    return 0
fi

# If executed directly, run the main function
monitoring_main "$@"