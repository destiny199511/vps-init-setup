# VPS One-Click Setup

[![Shell](https://img.shields.io/badge/shell-bash-grey)]()
[![License](https://img.shields.io/badge/license-MIT-blue)]()

**English** | [中文](README.md) | [日本語](README.ja.md) | [Español](README.es.md)

An initialization and security-hardening script for Linux VPS. It configures users, SSH, firewall, Docker, backups, monitoring, and system tuning through an interactive wizard or a config file.

## Getting Started

Run as `root` or with `sudo` on a fresh VPS:

```bash
curl -fsSL https://raw.githubusercontent.com/destiny199511/vps-init-setup/main/install.sh | sudo bash
```

The installer places the project at `/opt/vps-init-setup` and then launches the interactive main menu.

> Before changing the SSH port or firewall, keep your current session open. After the run completes, verify SSH login from a new terminal before closing the old one.

## Configuration

Enter the project directory:

```bash
cd /opt/vps-init-setup
```

### Interactive Wizard

```bash
sudo ./vps_setup.sh
```

The main menu offers:

1. Full wizard: collects system, user, cleanup, SSH, security, services, backup and monitoring settings in order.
2. Section configuration: adjust a single configuration category.
3. Configuration preview: review the parameters that will take effect.
4. Load or reset a config file.
5. Start the installation.
6. View module status.
7. View the latest health report.

In the wizard, press `Enter` to accept defaults; press `b` or `Esc` to go back one step. Arrow keys, `j`/`k`, and number keys are supported for menu selection. A card-style UI is used when the terminal is at least 60 columns wide and is a TTY; otherwise it falls back to a plain text menu.

### Unattended and Dry Run

```bash
# Create a local config file from the example
sudo install -m 600 examples/example_user_config.conf config/vps_config.conf

# Preview the changes without modifying the system
sudo ./vps_setup.sh -n -d

# Run installation using the config file or defaults
sudo ./vps_setup.sh -n

# Auto mode: non-interactive and skips confirmation
sudo ./vps_setup.sh -a

# Run only specific modules
sudo ./vps_setup.sh -n --modules 05_ssh,06_firewall

# Force re-run of completed modules
sudo ./vps_setup.sh -n -f
```

## Verifying the VPS State

After configuration completes, check the health report first:

```bash
sudo ./vps_setup.sh --health
```

The report compares the target configuration against the current system state and prints pass/warn/fail counts; files are saved to `logs/health_report_*.txt`.

Other useful checks:

```bash
# Whether modules completed, were skipped, or failed
sudo ./vps_setup.sh --status

# SSH login command and key execution results
cat config/install-result.env

# Log of this run
tail -f logs/vps_setup_*.log
```

At the end of each run a live status card is also shown, including hostname, timezone, locale, SSH port, firewall, swap, Docker, and Fail2ban.

## Feature Scope

| Category | Modules | Contents |
|---|---|---|
| Preflight & base | `00`-`03` | Permissions, system resources, hostname, timezone, locale, and DNS |
| Access security | `04`-`07` | Non-root admin user, SSH hardening, firewall, Fail2ban |
| Services & network | `08`-`09` | Docker, BBR, and TCP kernel parameters |
| Operations | `10`-`12` | Automatic backups, monitoring tools, security audit and scanning |
| Cleanup & tuning | `13` | Swap, Snap, cache, journal, and unused service cleanup |

## Common Options

```text
-n, --non-interactive   Use config file or defaults; do not enter the interactive menu
-a, --auto              Non-interactive mode and skip confirmation
-d, --dry-run           Dry run; do not modify the system
-f, --force             Force re-execution of completed modules
--modules <list>        Run only specified modules, e.g. 01_hostname,05_ssh
--status                Show module execution status
--health                Show the latest configuration health report
```

For the full option list, run:

```bash
sudo ./vps_setup.sh --help
```

## Updates and File Locations

```bash
curl -fsSL https://raw.githubusercontent.com/destiny199511/vps-init-setup/main/install.sh \
  | sudo bash -s -- --ref main --update-only
```

Updates preserve `config/`, `logs/`, and `backups/`. Key files:

- Configuration: `config/vps_config.conf`
- Execution results: `config/install-result.env`
- Run logs: `logs/vps_setup_*.log`
- Security audit logs: `logs/audit_*.log`
- Automatic backups and config snapshots: `backups/`

> `--rollback` is not fully implemented yet; to restore, use the snapshots in `backups/`.

## Compatibility

Primarily targets common VPS distributions such as Ubuntu, Debian, CentOS Stream, Rocky Linux, and AlmaLinux. Fresh machines may have background updates holding the APT lock; the script waits automatically, up to 300 seconds by default. Adjust with `APT_LOCK_WAIT=600`.

## License

[MIT License](LICENSE)
