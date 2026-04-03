#!/bin/bash
# ============================================
# ダッシュボード用データ生成スクリプト v2
# 担当者紐づけ・Issue詳細・トレンド対応
# ============================================

set -euo pipefail

ORG="BLITZ-AI-agent-team"
OUTPUT_DIR="${1:-docs}"
OUTPUT_FILE="$OUTPUT_DIR/data.json"
HISTORY_DIR="$OUTPUT_DIR/data-history"
TODAY=$(date -u +%Y-%m-%d)
YESTERDAY=$(date -u -d "yesterday" +%Y-%m-%d 2>/dev/null || date -u -v-1d +%Y-%m-%d 2>/dev/null || date -u +%Y-%m-%d)

echo "📊 ダッシュボードデータ生成 v2"
echo "Organization: $ORG"
echo "Date: $TODAY"

mkdir -p "$HISTORY_DIR"

REPOS=$(gh repo list "$ORG" --json name --limit 100 -q '.[].name' 2>/dev/null | grep -v "team-dashboard" || echo "")
MEMBERS=$(gh api "orgs/$ORG/members" --jq '.[].login' 2>/dev/null || echo "")

TOTAL_DONE=0
TOTAL_TASKS=0
TOTAL_COMMITS=0
ACTIVE_COUNT=0
MEMBER_COUNT=$(echo "$MEMBERS" | grep -c . 2>/dev/null || echo "0")

# === Python でJSON生成（堅牢なエスケープ処理）===
python3 << 'PYEOF'
import subprocess, json, sys, os, glob, re, base64, io
from datetime import datetime, timedelta, timezone
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

ORG = "BLITZ-AI-agent-team"
OUTPUT_DIR = sys.argv[1] if len(sys.argv) > 1 else "docs"
OUTPUT_FILE = f"{OUTPUT_DIR}/data.json"
HISTORY_DIR = f"{OUTPUT_DIR}/data-history"
TODAY = datetime.now(timezone.utc).strftime("%Y-%m-%d")

def gh(cmd):
    try:
        r = subprocess.run(f"gh {cmd}", shell=True, capture_output=True, text=True, timeout=30, encoding='utf-8', errors='replace')
        return r.stdout.strip()
    except:
        return ""

def gh_json(cmd):
    out = gh(cmd)
    try:
        return json.loads(out) if out else []
    except:
        return []

# リポジトリ・メンバー一覧
repos = [r["name"] for r in gh_json(f'repo list {ORG} --json name --limit 100') if r["name"] != "team-dashboard"]
members_list = gh_json(f'api orgs/{ORG}/members --jq "[.[].login]"')
if isinstance(members_list, str):
    members_list = json.loads(members_list) if members_list else []

print(f"Repos: {repos}")
print(f"Members: {members_list}")

# === プロジェクトデータ収集 ===
projects = []
total_done = 0
total_tasks = 0
total_commits = 0
all_alerts = []
all_recent_commits = []

for repo in repos:
    full = f"{ORG}/{repo}"
    tools = []

    # ファイル一覧取得
    tree = gh_json(f'api repos/{full}/git/trees/HEAD?recursive=1 --jq "[.tree[] | select(.type==\\"blob\\") | .path]"')
    if isinstance(tree, str):
        tree = json.loads(tree) if tree else []
    md_files = [f for f in tree if f.endswith('.md')
        and '_guide.' not in f.lower()
        and 'MTG' not in f
        and 'session_handoff' not in f
        and 'user_tasks' not in f
        and not f.startswith('.claude/')
        and not f.startswith('archive/')
        and not f.startswith('docs/research/')
        and 'SESSION_HANDOFF' not in f
        and 'CLAUDE.md' not in f
        and 'README.md' not in f
        and 'GITHUB_ISSUES' not in f
    ]

    # コミットメッセージから担当者×ツール紐づけを構築
    # コミットメッセージの先頭番号(例: "02: ...")からツールファイルを推定
    recent_commits_raw = gh_json(f'api repos/{full}/commits?since={TODAY}T00:00:00Z&per_page=30 --jq "[.[] | {{sha: .sha, author: (.author.login // .commit.author.name), message: (.commit.message | split(\\"\\n\\")[0]), date: .commit.author.date, files_url: .url}}]"')
    if isinstance(recent_commits_raw, str):
        recent_commits_raw = json.loads(recent_commits_raw) if recent_commits_raw else []

    # 昨日分も取得
    yesterday_commits = gh_json(f'api "repos/{full}/commits?since={(datetime.now(timezone.utc)-timedelta(days=1)).strftime("%Y-%m-%d")}T00:00:00Z&until={TODAY}T00:00:00Z&per_page=30" --jq "[.[] | {{sha: .sha, author: (.author.login // .commit.author.name), message: (.commit.message | split(\\"\\n\\")[0]), date: .commit.author.date}}]"')
    if isinstance(yesterday_commits, str):
        yesterday_commits = json.loads(yesterday_commits) if yesterday_commits else []

    all_commits = recent_commits_raw + yesterday_commits
    total_commits += len(all_commits)

    # 担当者マッピング
    # 方式1: コミットメッセージの先頭番号（02: xxx）からツール別に特定
    tool_assignees = {}
    for c in all_commits:
        msg = c.get("message", "")
        author = c.get("author", "unknown")
        m = re.match(r'^(\d{2})[:：\s]', msg)
        if m:
            prefix = m.group(1)
            if prefix not in tool_assignees:
                tool_assignees[prefix] = author

    # 方式2: リポジトリ全体で最もコミットしている人 = リポジトリ担当者
    repo_contributors = gh_json(f'api repos/{full}/contributors --jq "[.[] | {{login: .login, contributions: .contributions}}]"')
    if isinstance(repo_contributors, str):
        repo_contributors = json.loads(repo_contributors) if repo_contributors else []
    repo_top_contributor = None
    if repo_contributors and isinstance(repo_contributors, list) and len(repo_contributors) > 0:
        repo_contributors.sort(key=lambda x: x.get("contributions", 0), reverse=True)
        repo_top_contributor = repo_contributors[0].get("login")

    # コミット詳細を収集
    for c in all_commits[:10]:  # 直近10件
        sha = c.get("sha", "")
        if not sha:
            continue
        detail = gh_json(f'api repos/{full}/commits/{sha} --jq "{{files: (.files | length), additions: .stats.additions, deletions: .stats.deletions}}"')
        if isinstance(detail, str):
            detail = json.loads(detail) if detail else {}
        all_recent_commits.append({
            "author": c.get("author", "unknown"),
            "repo": repo,
            "message": c.get("message", ""),
            "date": c.get("date", ""),
            "files": detail.get("files", 0) if isinstance(detail, dict) else 0,
            "additions": detail.get("additions", 0) if isinstance(detail, dict) else 0,
            "deletions": detail.get("deletions", 0) if isinstance(detail, dict) else 0
        })

    # 各要件定義書を解析 → まず全件読み込み、後で重複排除
    raw_tools = []
    for f in md_files:
        content_b64 = gh(f'api repos/{full}/contents/{f} --jq .content')
        if not content_b64:
            continue
        try:
            content = base64.b64decode(content_b64).decode('utf-8')
        except:
            continue

        title = content.split('\n')[0].lstrip('# ').strip()
        is_req = any(kw in title for kw in ['要件定義書', '仕様書', 'requirements', 'Requirements'])
        if not is_req:
            continue

        # チェックリスト抽出
        unchecked = [l.strip().lstrip('- [ ] ') for l in content.split('\n') if re.match(r'^\s*- \[ \]', l)]
        checked = [l.strip().lstrip('- [x] ') for l in content.split('\n') if re.match(r'^\s*- \[x\]', l)]
        tool_total = len(unchecked) + len(checked)
        tool_done = len(checked)

        # ステータス
        if tool_total == 0:
            status = "unknown"
        elif tool_done == tool_total:
            status = "green"
        elif tool_done > 0:
            status = "yellow"
        else:
            status = "red"

        # ツール名
        clean_name = re.sub(r'\s*(要件定義書|仕様書).*$', '', title)

        # バージョン番号を抽出（v2.0, v2.1, v3.0 等）
        ver_match = re.search(r'v(\d+)\.(\d+)', title) or re.search(r'v(\d+)', title)
        if ver_match:
            ver_tuple = tuple(int(x) for x in ver_match.groups())
        else:
            ver_tuple = (0,)

        # システム名を抽出（バージョン番号を除いた部分）
        system_name = re.sub(r'\s*v\d+[\.\d]*\s*[-:]?\s*', ' ', clean_name).strip()
        system_name = re.sub(r'\s+', ' ', system_name)

        # モジュール名を検出（"- 売上照合", "- 顧客管理" 等のサブタイトル）
        module_match = re.search(r'[-–—]\s*(.+)$', clean_name)
        module_name = module_match.group(1).strip() if module_match else None

        # ファイル番号プレフィクスから担当者を取得
        file_prefix = re.match(r'^(\d{2})_', f)
        assignee = None
        if file_prefix:
            assignee = tool_assignees.get(file_prefix.group(1))

        raw_tools.append({
            "file": f, "title": title, "clean_name": clean_name,
            "system_name": system_name, "module_name": module_name,
            "version": ver_tuple, "ver_str": ver_match.group(0) if ver_match else "",
            "done": tool_done, "total": tool_total, "status": status,
            "assignee": assignee, "unchecked": unchecked, "checked": checked
        })

    # --- バージョン重複排除 ---
    # 同じシステム名で、モジュール名がないもの同士 → 最新バージョンだけ残す
    # モジュール名があるもの → 独立したツールとして残す
    filtered_tools = []
    # システム名ごとにグルーピング
    system_groups = {}
    for t in raw_tools:
        if t["module_name"]:
            # モジュールは独立して残す
            filtered_tools.append(t)
        else:
            key = t["system_name"]
            if key not in system_groups:
                system_groups[key] = []
            system_groups[key].append(t)

    # 各システムの最新バージョンだけを残す
    for key, versions in system_groups.items():
        versions.sort(key=lambda x: x["version"], reverse=True)
        latest = versions[0]
        filtered_tools.append(latest)

    # フィルタ後のツールでデータを構築
    for t in filtered_tools:
        total_done += t["done"]
        total_tasks += t["total"]

        # 担当者の決定（優先順位: コミットメッセージ番号 > リポジトリ最多コミッター）
        file_prefix = re.match(r'^(\d{2})_', t["file"])
        assignee = t["assignee"]
        if not assignee and file_prefix:
            assignee = tool_assignees.get(file_prefix.group(1))
        if not assignee:
            assignee = repo_top_contributor

        # 表示名にバージョンとモジュール情報を含める
        display_name = t["clean_name"]
        if t["module_name"] and t["ver_str"]:
            display_name = f'{t["module_name"]} ({t["ver_str"]})'
        elif t["ver_str"]:
            display_name = f'{t["system_name"]} ({t["ver_str"]})'

        tools.append({
            "name": display_name,
            "file": t["file"],
            "done": t["done"],
            "total": t["total"],
            "status": t["status"],
            "assignee": assignee,
            "remaining_tasks": t["unchecked"][:20],
            "completed_tasks": t["checked"][:10]
        })

    projects.append({"name": repo, "tools": tools})

# === メンバー別データ ===
members_data = []
active_count = 0
for member in members_list:
    member_commits = 0
    last_push = None
    working_on = "-"
    working_tool = "-"

    for repo in repos:
        count_str = gh(f'api repos/{ORG}/{repo}/commits?author={member}&since={(datetime.now(timezone.utc)-timedelta(days=1)).strftime("%Y-%m-%d")}T00:00:00Z --jq length')
        count = int(count_str) if count_str.isdigit() else 0
        member_commits += count
        if count > 0:
            working_on = repo
            last_push = TODAY
            # 最新コミットメッセージからツール特定
            last_msg = gh(f'api repos/{ORG}/{repo}/commits?author={member}&per_page=1 --jq ".[0].commit.message | split(\\"\\n\\")[0]"')
            m = re.match(r'^(\d{2})[:：\s]', last_msg)
            if m:
                prefix = m.group(1)
                for proj in projects:
                    for t in proj.get("tools", []):
                        if t["file"].startswith(prefix + "_"):
                            working_tool = t["name"]
                            break

    if not last_push:
        for repo in repos:
            lp = gh(f'api repos/{ORG}/{repo}/commits?author={member}&per_page=1 --jq ".[0].commit.author.date // empty"')
            if lp:
                last_push = lp[:10]
                working_on = repo
                break

    if member_commits > 0:
        m_status = "active"
        active_count += 1
    elif last_push:
        m_status = "warning"
    else:
        m_status = "inactive"

    members_data.append({
        "login": member,
        "display": member,
        "last_push": last_push,
        "commits_today": member_commits,
        "status": m_status,
        "working_on": working_on,
        "working_tool": working_tool
    })

# === アラート ===
inactive_count = len(members_list) - active_count
if inactive_count > 0:
    all_alerts.append({"type": "warning", "message": f"{inactive_count}名が直近2日間pushしていません"})

# 停滞ツール検知（チェックリストがあるのに進捗0%）
for proj in projects:
    for t in proj.get("tools", []):
        if t["status"] == "red" and t["total"] > 0:
            all_alerts.append({"type": "error", "message": f"{t['name']}: {t['total']}件のタスクが全て未着手です"})

# === チーム全体ヘルス ===
total_pct = (total_done * 100 // total_tasks) if total_tasks > 0 else 0
if active_count >= (len(members_list) // 2 + 1) and len([a for a in all_alerts if a["type"] == "error"]) == 0:
    team_health = "green"
elif active_count >= 1:
    team_health = "yellow"
else:
    team_health = "red"

# === 週次トレンド（過去7日分のhistoryから） ===
trend_labels = []
trend_progress = []
trend_commits = []
for i in range(6, -1, -1):
    d = (datetime.now(timezone.utc) - timedelta(days=i)).strftime("%Y-%m-%d")
    trend_labels.append(d[5:])  # MM-DD
    hist_file = f"{HISTORY_DIR}/{d}.json"
    if os.path.exists(hist_file):
        try:
            with open(hist_file) as hf:
                hdata = json.load(hf)
                trend_progress.append(hdata.get("total_progress", {}).get("percent", 0))
                trend_commits.append(hdata.get("recent_commit_count", 0))
        except:
            trend_progress.append(0)
            trend_commits.append(0)
    else:
        # 今日のデータ
        if i == 0:
            trend_progress.append(total_pct)
            trend_commits.append(total_commits)
        else:
            trend_progress.append(0)
            trend_commits.append(0)

# === JSON出力 ===
output = {
    "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "team_health": team_health,
    "total_progress": {"done": total_done, "total": total_tasks, "percent": total_pct},
    "active_members": {"active": active_count, "total": len(members_list)},
    "recent_commit_count": total_commits,
    "alerts": all_alerts,
    "projects": projects,
    "members": members_data,
    "recent_commits": all_recent_commits[:15],
    "weekly_trend": {
        "labels": trend_labels,
        "progress": trend_progress,
        "commits": trend_commits
    }
}

os.makedirs(OUTPUT_DIR, exist_ok=True)
with open(OUTPUT_FILE, 'w', encoding='utf-8') as f:
    json.dump(output, f, ensure_ascii=False, indent=2)

print(f"✅ データ生成完了: {OUTPUT_FILE}")
print(f"   プロジェクト: {len(projects)}, ツール: {sum(len(p['tools']) for p in projects)}, 進捗: {total_pct}%")
PYEOF
