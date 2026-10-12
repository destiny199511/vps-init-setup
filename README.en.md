# VPS One-Click Setup

[![Shell](https://img.shields.io/badge/shell-bash-grey)]()
[![License](https://img.shields.io/badge/license-MIT-blue)]()

**English** | [中文](README.md) | [日本語](README.ja.md) | [Español](README.es.md)

An initialization and security-hardening script for Linux VPS. It configures users, SSH, firewall, Docker, backups, monitoring, and system tuning through an interactive wizard or a config file.

## Getting Started

### Quick Start (Recommended)

Run on a fresh Linux VPS as `root` or with `sudo`:

```bash
# 1. Clone the repository
git clone https://github.com/destiny199511/vps-init-setup.git
cd vps-init-setup

# 2. Launch the interactive setup wizard
sudo ./vps_setup.sh
```

### Production Secure Install (Verify Release Signature & Archive)

For production environments, install via pinned immutable Git commit and independent SHA-256 checksums:

```bash
export VPS_COMMIT="<40-hex-commit>"
export ARCHIVE_SHA256="<release-archive-sha256>"
export INSTALLER_SHA256="<release-installer-sha256>"

# Download and verify the installer
curl -fsSLo install.sh "https://raw.githubusercontent.com/destiny199511/vps-init-setup/${VPS_COMMIT}/install.sh"
printf '%s  %s\n' "$INSTALLER_SHA256" install.sh | sha256sum -c -

# Verify source archive and install to /opt/vps-init-setup
sudo bash install.sh --ref "$VPS_COMMIT" --sha256 "$ARCHIVE_SHA256"
```

> 💡 **Release Verification**: Releases publish `source-commit.txt`, SHA-256 manifests, and GitHub build provenance attestations (verifiable via `gh attestation verify`).
> ⚠️ **Anti-Lockout Notice**: Keep your active SSH session open before modifying SSH ports or firewall rules. Verify login in a new terminal before disconnecting.

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
8. Inspect common system configuration (live status of user, SSH, firewall, Docker, backup, monitoring, kernel optimization).

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

Inspect common system configuration and live status:

```bash
# View all common configurations (User/SSH/Firewall/Docker/Backup/Monitoring/Optimization)
sudo ./vps_setup.sh --view

# Inspect specific categories
sudo ./vps_setup.sh --view user
sudo ./vps_setup.sh --view ssh
sudo ./vps_setup.sh --view firewall
sudo ./vps_setup.sh --view docker
sudo ./vps_setup.sh --view backup
sudo ./vps_setup.sh --view monitoring
sudo ./vps_setup.sh --view optimization
```

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
--view, --show-config   Inspect common system configuration (sections: all, user, ssh, firewall, docker, backup, monitoring, optimization)
--set-password [user]   Set or change user password for system & sudo (alias: --passwd)
```

For the full option list, run:

```bash
sudo ./vps_setup.sh --help
```

## Updates and File Locations

Updates use the same pinned commit and independently verified SHA-256 values:

```bash
sudo bash install.sh --ref "$VPS_COMMIT" --sha256 "$ARCHIVE_SHA256" --update-only
```

Common parameters supported by `install.sh`:
- `--ref <40-hex-commit>`: Specify an immutable 40-character Git commit (required for remote installs).
- `--sha256 <hash>`: Expected SHA-256 for that commit's source archive (required for remote installs).
- `--update-only`: Update script files without launching the setup wizard.

Updates preserve `config/`, `logs/`, and `backups/`. Key files:

- Configuration: `config/vps_config.conf`
- Execution results: `config/install-result.env`
- Run logs: `logs/vps_setup_*.log`
- Security audit logs: `logs/audit_*.log`
- Automatic backups and config snapshots: `backups/`

> `--rollback` automatically restores tracked system configuration files from the latest transaction; system user accounts, packages, and kernel settings can be reviewed and managed with `backups/` snapshots and audit logs.

## Troubleshooting & Verification

- **Production Install and Tamper Prevention**:
  Mutable branches and skipped verification are unsupported. Obtain the commit and both SHA-256 values from an independently verified release record, then follow the verification flow at the top of this document.

## Compatibility

Primarily targets common VPS distributions such as Ubuntu, Debian, CentOS Stream, Rocky Linux, and AlmaLinux. Fresh machines may have background updates holding the APT lock; the script waits automatically, up to 300 seconds by default. Adjust with `APT_LOCK_WAIT=600`.

## License

[MIT License](LICENSE)
