# VPS 一键装机

[![Shell](https://img.shields.io/badge/shell-bash-grey)]()
[![License](https://img.shields.io/badge/license-MIT-blue)]()

面向 Linux VPS 的初始化与安全加固脚本。它通过交互式向导或配置文件完成用户、SSH、防火墙、Docker、备份、监控和系统优化等常用配置。

## 开始使用

在新的 VPS 上以 `root` 或 `sudo` 运行：

```bash
curl -fsSL https://raw.githubusercontent.com/destiny199511/vps-init-setup/main/install.sh | sudo bash
```

安装器默认将项目放在 `/opt/vps-init-setup`，随后会启动交互式主菜单。

> 修改 SSH 端口或防火墙前，请保留当前会话。执行完成后，先在新终端测试 SSH 登录成功，再关闭旧会话。

## 配置方式

进入项目目录：

```bash
cd /opt/vps-init-setup
```

### 交互式向导

```bash
sudo ./vps_setup.sh
```

主菜单提供：

1. 完整向导：依次收集系统、用户、清理、SSH、安全、服务、备份监控配置。
2. 分项配置：只调整某个配置类别。
3. 配置预览：检查即将生效的参数。
4. 加载或重置配置文件。
5. 开始执行安装。
6. 查看模块状态。
7. 查看最近的配置体检报告。

向导中可直接按 `Enter` 使用默认值，按 `b`、`Esc` 返回上一步；支持方向键、`j`/`k` 和数字键选择菜单项。终端宽度至少 60 列且为 TTY 时使用卡片式界面，否则自动降级为文本菜单。

### 无人值守与试运行

```bash
# 从示例创建本地配置文件
sudo install -m 600 examples/example_user_config.conf config/vps_config.conf

# 预览将执行的变更，不修改系统
sudo ./vps_setup.sh -n -d

# 使用配置文件或默认值执行安装
sudo ./vps_setup.sh -n

# 自动模式：非交互并跳过确认
sudo ./vps_setup.sh -a

# 只执行指定模块
sudo ./vps_setup.sh -n --modules 05_ssh,06_firewall

# 强制重跑已完成模块
sudo ./vps_setup.sh -n -f
```

## 验证实际 VPS 状态

配置执行结束后，优先查看体检报告：

```bash
sudo ./vps_setup.sh --health
```

报告会比对目标配置与当前系统状态，并输出通过、提示、失败计数；文件保存在 `logs/health_report_*.txt`。

其他常用检查：

```bash
# 模块是否完成、跳过或失败
sudo ./vps_setup.sh --status

# SSH 登录命令和关键执行结果
cat config/install-result.env

# 本次运行日志
tail -f logs/vps_setup_*.log
```

每次执行收尾也会直接显示实时状态卡片，包括主机名、时区、语言、SSH 端口、防火墙、Swap、Docker 和 Fail2ban。

## 功能范围

| 类别 | 模块 | 主要内容 |
|---|---|---|
| 预检与基础 | `00`-`03` | 权限、系统资源、主机名、时区、语言与 DNS |
| 访问安全 | `04`-`07` | 非 root 管理用户、SSH 加固、防火墙、Fail2ban |
| 服务与网络 | `08`-`09` | Docker、BBR 与 TCP 内核参数 |
| 运维能力 | `10`-`12` | 自动备份、监控工具、安全审计与扫描 |
| 清理优化 | `13` | Swap、Snap、缓存、Journal 与无用服务清理 |

## 常用参数

```text
-n, --non-interactive   使用配置文件或默认值，不进入交互菜单
-a, --auto              非交互模式并跳过确认
-d, --dry-run           试运行，不修改系统
-f, --force             强制重新执行已完成模块
--modules <list>        仅执行指定模块，如 01_hostname,05_ssh
--status                显示模块执行状态
--health                查看最近一次配置体检报告
```

完整参数说明请运行：

```bash
sudo ./vps_setup.sh --help
```

## 更新与文件位置

```bash
curl -fsSL https://raw.githubusercontent.com/destiny199511/vps-init-setup/main/install.sh \
  | sudo bash -s -- --ref main --update-only
```

更新会保留 `config/`、`logs/` 与 `backups/`。关键文件：

- 配置：`config/vps_config.conf`
- 执行结果：`config/install-result.env`
- 运行日志：`logs/vps_setup_*.log`
- 安全审计日志：`logs/audit_*.log`
- 自动备份与配置快照：`backups/`

> `--rollback` 当前尚未完整实现；需要恢复时，请使用 `backups/` 中的快照。

## 兼容性

主要面向 Ubuntu、Debian、CentOS Stream、Rocky Linux 和 AlmaLinux 等常见 VPS 发行版。新机器可能会有后台更新占用 APT 锁，脚本会自动等待，默认最长 300 秒；可用 `APT_LOCK_WAIT=600` 调整。

## 许可证

[MIT License](LICENSE)
