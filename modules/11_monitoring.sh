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
                    install_package netdata
                    ;;
                *)
                    log_error "Netdata must be installed from a signed distribution package repository on this OS"
                    return 1
                    ;;
            esac
        fi

        if ! systemctl enable --now netdata 2>/dev/null && ! service netdata start 2>/dev/null; then
            log_error "Netdata package installed but its service could not be started"
            return 1
        fi
        if command -v netdata >/dev/null 2>&1 && systemctl is-active --quiet netdata; then
            log_info "Netdata installed and running"
            changes_made=true
            audit "MONITORING_NETDATA_INSTALLED" "port=19999"
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
                install_package prometheus-node-exporter
                if ! systemctl enable --now prometheus-node-exporter; then
                    log_error "Prometheus Node Exporter package installed but its service could not be started"
                    return 1
                fi
                ;;
            dnf|yum|rpm)
                install_package node_exporter
                if ! systemctl enable --now node_exporter; then
                    log_error "Prometheus Node Exporter package installed but its service could not be started"
                    return 1
                fi
                ;;
            *)
                log_error "Node Exporter must be installed from a signed distribution package repository on this OS"
                return 1
                ;;
        esac
        changes_made=true
        log_info "Prometheus Node Exporter installed on port 9100"
        audit "MONITORING_PROMETHEUS_NODE_INSTALLED" "port=9100"
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