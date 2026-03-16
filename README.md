# Autonomous Agent Unit (AAU)

Claude Code ベースの自律型AIエージェントオーケストレーションシステム。
チーム構成・通知先・スケジュールを `aau.yaml` 1ファイルで設定するだけで、
複数のAIエージェントが自律的にタスクを処理し続ける。

## 特徴

- **ゼロトークン設計**: アクション不要時はClaude APIを呼ばない（コスト最小化）
- **自律駆動ループ**: 30分ごとにプロジェクト状態を判断し、タスク作成・進捗監視・報告を自動実行
- **ファイルベースIPC**: tasks.md / progress.md によるシンプルなチーム間通信
- **セルフヒーリング**: エージェント停止を自動検知し、ロック解放・再起動
- **クロスプラットフォーム**: macOS (launchd) / Linux (systemd) 対応
- **プラグイン通知**: Slack / Discord / Webhook / なし

## クイックスタート

```bash
# 1. クローン
git clone <this-repo> ~/git/autonomous-agent-unit

# 2. プロジェクトディレクトリで初期化
cd ~/git/my-project
~/git/autonomous-agent-unit/setup.sh

# 3. 対話的に設定
#    - プロジェクト名
#    - チームメンバー（例: coder,qa,designer）
#    - 通知プラグイン（Slack等）
#    - 言語（ja/en）

# 4. タスクを追加して開始
echo "## TASK-001 [PENDING]
最初のタスク内容" >> team/coder/tasks.md
```

## アーキテクチャ

```
                    ┌─────────────────┐
                    │  aau.yaml       │  ← 全設定の単一ソース
                    └────────┬────────┘
                             │
              ┌──────────────┼──────────────┐
              │              │              │
     ┌────────▼───────┐ ┌───▼────┐ ┌───────▼───────┐
     │ Director       │ │ Task   │ │ Health        │
     │ Autonomous     │ │ Monitor│ │ Monitor       │
     │ (30min)        │ │ (5min) │ │ (10min)       │
     └───────┬────────┘ └───┬────┘ └───────┬───────┘
             │              │              │
             │         ┌────▼────┐         │
             │         │ Trigger │         │
             │         │ Files   │         │
             │         └────┬────┘         │
             │              │              │
        ┌────▼──────────────▼──────────────▼────┐
        │           Agent Runners                │
        │  ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐ │
        │  │Coder │ │ QA   │ │Design│ │ ...  │ │
        │  └──────┘ └──────┘ └──────┘ └──────┘ │
        └───────────────────────────────────────┘
```

### 状態判定モード（優先順）

| モード | 条件 | アクション |
|--------|------|-----------|
| `REPORT_DUE` | 最終報告から2時間超過 | 状況整理→通知 |
| `DONE_FOLLOWUP` | 未処理のDONEタスクあり | フォローアップタスク作成 |
| `STALE_PROGRESS` | IN_PROGRESSだが30分更新なし | 調査→タスク分割 |
| `IDLE_ALL` | 全エージェントアイドル | タスク一括作成 |
| `NO_ACTION` | 正常進行中 | 即終了（トークン0） |

## ディレクトリ構成

```
autonomous-agent-unit/
├── setup.sh                    # 対話的セットアップウィザード
├── aau.yaml.example            # 設定ファイルのテンプレート
├── lib/
│   ├── config.sh               # YAML→シェル変数パーサー
│   ├── common.sh               # 共通関数（ロック・ログ・通知）
│   ├── director_autonomous.sh  # 自律駆動ループ
│   ├── director_responder.sh   # inbox応答
│   ├── agent_runner.sh         # エージェント実行
│   ├── task_monitor.sh         # タスクファイル監視
│   └── health_monitor.py       # ヘルスモニタリング
├── platform/
│   ├── launchd/                # macOS用
│   └── systemd/                # Linux用
├── plugins/
│   ├── slack/                  # Slack通知
│   ├── discord/                # Discord通知
│   └── webhook/                # 汎用Webhook
├── templates/
│   └── prompts/{ja,en}/        # 言語別プロンプトテンプレート
├── init/
│   └── scaffold.sh             # team/ディレクトリ生成
└── tests/                      # テストスイート
```

## 設定 (aau.yaml)

```yaml
project:
  name: "my-project"

runtime:
  claude_cli: "/opt/homebrew/bin/claude"
  claude_model: "claude-sonnet-4-6"
  prefix: "myproj"              # /tmp/{prefix}_* のプレフィックス

team:
  members:
    - name: coder
      role: "Implementation"
      timeout: 600              # Claude実行タイムアウト（秒）
      max_turns: 30
      interval: 300             # スケジューラ実行間隔（秒）
    - name: qa
      role: "Testing"
      timeout: 600
      max_turns: 30
      interval: 300

director:
  autonomous_interval: 1800     # 自律ループ間隔
  report_interval: 7200         # 報告間隔
  stale_threshold: 1800         # 膠着判定閾値
  daily_max_invocations: 20     # 日次Claude上限
  quiet_hours_start: 0          # 停止開始時刻
  quiet_hours_end: 8            # 停止終了時刻

notification:
  plugin: "slack"               # slack | discord | webhook | none

prompts:
  language: "ja"                # ja | en
```

## 通知プラグイン

### Slack
`.env` に以下を設定:
```
SLACK_TOKEN=xoxb-your-token
SLACK_CHANNEL=C0123456789
```

### Webhook
`.env` に以下を設定:
```
WEBHOOK_URL=https://your-webhook-endpoint
```

## 安全機構

- **PIDベースロック**: 二重起動防止 + 経過時間で強制解放
- **日次上限**: 1日あたりのClaude起動回数制限（デフォルト20回）
- **深夜停止**: 設定可能な静粛時間帯
- **指数バックオフ**: 失敗時のリトライ間隔増加
- **セルフヒーリング**: ロック残存・エージェント停止の自動検知と復旧
- **ログローテーション**: 10MB超過で自動切り詰め

## 管理コマンド

```bash
# macOS: サービス状態確認
launchctl list | grep ai.myproject

# macOS: 再起動
launchctl unload ~/Library/LaunchAgents/ai.myproject.agent-coder.plist
launchctl load   ~/Library/LaunchAgents/ai.myproject.agent-coder.plist

# Linux: タイマー確認
systemctl --user list-timers | grep aau-myproject

# ログ確認
tail -f /tmp/myproj_director_autonomous.log
tail -f /tmp/myproj_agent_coder.log

# 構造化ログ（JSONL）
cat /tmp/myproj_director_autonomous.jsonl | python3 -m json.tool

# テスト実行
bash tests/test_config_loader.sh
bash tests/test_state_detection.sh

# アンインストール
bash platform/launchd/uninstall.sh   # macOS
bash platform/systemd/uninstall.sh   # Linux
```

## PCC (Pixel Creature Craft) からの移行

このパッケージはPCCプロジェクトで実証された自律エージェントシステムを汎用化したもの。

PCC固有だった要素:
- ハードコードされたSlackトークン → `.env`
- 固定チーム構成(coder/artist/qa/assistant) → `aau.yaml`で設定可能
- macOS専用 → macOS + Linux対応
- 日本語固定 → 日英テンプレート
- 190箇所のハードコード → 1ファイル(`aau.yaml`)に集約

## ライセンス

MIT
