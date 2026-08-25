# VPS ワンクリックセットアップ

[![Shell](https://img.shields.io/badge/shell-bash-grey)]()
[![License](https://img.shields.io/badge/license-MIT-blue)]()

[English](README.en.md) | [中文](README.md) | **日本語** | [Español](README.es.md)

Linux VPS 向けの初期化・セキュリティ強化スクリプトです。インタラクティブなウィザードまたは設定ファイルを通じて、ユーザー、SSH、ファイアウォール、Docker、バックアップ、監視、システム最適化などを設定します。

## はじめに

新しい VPS で `root` または `sudo` で実行します：

```bash
curl -fsSL https://raw.githubusercontent.com/destiny199511/vps-init-setup/main/install.sh | sudo bash
```

インストーラーはプロジェクトを `/opt/vps-init-setup` に配置し、その後インタラクティブなメインメニューを起動します。

> SSH ポートやファイアウォールを変更する前に、現在のセッションは開いたままにしてください。実行完了後、新しいターミナルで SSH ログインを確認してから、古いセッションを閉じてください。

## 設定方法

プロジェクトディレクトリに移動します：

```bash
cd /opt/vps-init-setup
```

### インタラクティブウィザード

```bash
sudo ./vps_setup.sh
```

メインメニューの内容：

1. フルウィザード：システム、ユーザー、クリーンアップ、SSH、セキュリティ、サービス、バックアップ・監視の設定を順番に収集します。
2. セクション設定：特定の設定カテゴリのみを調整します。
3. 設定プレビュー：有効になるパラメータを確認します。
4. 設定ファイルの読み込みまたはリセット。
5. インストールの開始。
6. モジュールの状態を表示。
7. 最新のヘルスレポートを表示。

ウィザードでは `Enter` でデフォルト値を使用でき、`b` または `Esc` で一つ前のステップに戻れます。メニュー選択は矢印キー、`j`/`k`、数字キーに対応しています。端末の幅が 60 列以上で TTY の場合はカード型 UI が使用され、それ以外はテキストメニューに自動で切り替わります。

### 無人実行とドライラン

```bash
# サンプルからローカル設定ファイルを作成
sudo install -m 600 examples/example_user_config.conf config/vps_config.conf

# システムを変更せずに変更内容をプレビュー
sudo ./vps_setup.sh -n -d

# 設定ファイルまたはデフォルト値でインストールを実行
sudo ./vps_setup.sh -n

# 自動モード：非対話型で確認もスキップ
sudo ./vps_setup.sh -a

# 指定したモジュールのみ実行
sudo ./vps_setup.sh -n --modules 05_ssh,06_firewall

# 完了済みモジュールを強制的に再実行
sudo ./vps_setup.sh -n -f
```

## VPS の状態確認

設定実行後は、まずヘルスレポートを確認してください：

```bash
sudo ./vps_setup.sh --health
```

レポートは目標設定と現在のシステム状態を比較し、成功・警告・失敗の件数を出力します。ファイルは `logs/health_report_*.txt` に保存されます。

その他の便利な確認方法：

```bash
# モジュールが完了・スキップ・失敗したかを表示
sudo ./vps_setup.sh --status

# SSH ログインコマンドと主要な実行結果
cat config/install-result.env

# 今回の実行ログ
tail -f logs/vps_setup_*.log
```

各実行の終わりには、ホスト名、タイムゾーン、ロケール、SSH ポート、ファイアウォール、Swap、Docker、Fail2ban を含むライブステータスカードも表示されます。

## 機能範囲

| カテゴリ | モジュール | 内容 |
|---|---|---|
| 事前チェック・基礎 | `00`-`03` | 権限、システムリソース、ホスト名、タイムゾーン、ロケール、DNS |
| アクセスセキュリティ | `04`-`07` | 非 root 管理ユーザー、SSH 強化、ファイアウォール、Fail2ban |
| サービス・ネットワーク | `08`-`09` | Docker、BBR、TCP カーネルパラメータ |
| 運用機能 | `10`-`12` | 自動バックアップ、監視ツール、セキュリティ監査・スキャン |
| クリーンアップ・最適化 | `13` | Swap、Snap、キャッシュ、ジャーナル、不要サービスのクリーンアップ |

## 主なオプション

```text
-n, --non-interactive   設定ファイルまたはデフォルト値を使用し、対話メニューに入らない
-a, --auto              非対話モードで確認もスキップ
-d, --dry-run           ドライラン。システムを変更しない
-f, --force             完了済みモジュールを強制的に再実行
--modules <list>        指定したモジュールのみ実行。例：01_hostname,05_ssh
--status                モジュールの実行状態を表示
--health                最新の設定ヘルスレポートを表示
```

すべてのオプションについては、以下を実行してください：

```bash
sudo ./vps_setup.sh --help
```

## 更新とファイルの場所

```bash
curl -fsSL https://raw.githubusercontent.com/destiny199511/vps-init-setup/main/install.sh \
  | sudo bash -s -- --ref main --update-only
```

更新時には `config/`、`logs/`、`backups/` が保持されます。主要なファイル：

- 設定：`config/vps_config.conf`
- 実行結果：`config/install-result.env`
- 実行ログ：`logs/vps_setup_*.log`
- セキュリティ監査ログ：`logs/audit_*.log`
- 自動バックアップと設定スナップショット：`backups/`

> `--rollback` はまだ完全には実装されていません。復元が必要な場合は `backups/` 内のスナップショットを使用してください。

## 互換性

主に Ubuntu、Debian、CentOS Stream、Rocky Linux、AlmaLinux などの一般的な VPS ディストリビューションを対象としています。新しいマシンではバックグラウンド更新が APT ロックを保持している場合があります。スクリプトは自動的に待機し、デフォルトで最大 300 秒待ちます。`APT_LOCK_WAIT=600` で調整できます。

## ライセンス

[MIT License](LICENSE)
