#!/bin/bash
# ============================================
# ダッシュボード用データ生成スクリプト
# GitHub APIからデータを取得してdata.jsonを生成
# ============================================

set -euo pipefail

ORG="BLITZ-AI-agent-team"
OUTPUT_DIR="${1:-docs}"
OUTPUT_FILE="$OUTPUT_DIR/data.json"
TODAY=$(date -u +%Y-%m-%d)
YESTERDAY=$(date -u -d "yesterday" +%Y-%m-%d 2>/dev/null || date -u -v-1d +%Y-%m-%d 2>/dev/null || date -u +%Y-%m-%d)

echo "📊 ダッシュボードデータ生成"
echo "Organization: $ORG"
echo "Date: $TODAY"

# リポジトリ一覧
REPOS=$(gh repo list "$ORG" --json name --limit 100 -q '.[].name' 2>/dev/null | grep -v "team-dashboard" || echo "")
MEMBERS=$(gh api "orgs/$ORG/members" --jq '.[].login' 2>/dev/null || echo "")

# プロジェクトデータ収集
PROJECTS_JSON="["
TOTAL_DONE=0
TOTAL_TASKS=0
TOTAL_COMMITS=0
ACTIVE_COUNT=0
MEMBER_COUNT=$(echo "$MEMBERS" | grep -c . 2>/dev/null || echo "0")
ALERTS_JSON="["
RECENT_COMMITS_JSON="["
MEMBERS_JSON="["

for REPO in $REPOS; do
    FULL_REPO="$ORG/$REPO"
    TOOLS_JSON="["

    # 全mdファイルを取得（要件定義書候補）
    ALL_MD=$(gh api "repos/$FULL_REPO/git/trees/HEAD?recursive=1" \
        --jq '.tree[] | select(.type=="blob") | .path' 2>/dev/null \
        | grep '\.md$' | grep -v '_guide\.' | grep -v 'MTG' | grep -v 'session_handoff' | grep -v 'user_tasks' \
        || echo "")

    for FILE in $ALL_MD; do
        CONTENT=$(gh api "repos/$FULL_REPO/contents/$FILE" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null || echo "")
        [ -z "$CONTENT" ] && continue

        TITLE=$(echo "$CONTENT" | head -1 | sed 's/^# //')
        # 要件定義書/仕様書のみ対象
        IS_REQ=$(echo "$TITLE" | grep -ciE '要件定義書|仕様書|requirements' || true)
        [ "$IS_REQ" -eq 0 ] && continue

        UNCHECKED=$(echo "$CONTENT" | grep -cE '^\s*- \[ \]' || true)
        CHECKED=$(echo "$CONTENT" | grep -cE '^\s*- \[x\]' || true)
        TOOL_TOTAL=$((UNCHECKED + CHECKED))
        TOOL_DONE=$CHECKED
        TOTAL_DONE=$((TOTAL_DONE + TOOL_DONE))
        TOTAL_TASKS=$((TOTAL_TASKS + TOOL_TOTAL))

        # ステータス判定
        if [ "$TOOL_TOTAL" -eq 0 ]; then
            STATUS="unknown"
        elif [ "$TOOL_DONE" -eq "$TOOL_TOTAL" ]; then
            STATUS="green"
        elif [ "$TOOL_DONE" -gt 0 ]; then
            STATUS="yellow"
        else
            STATUS="red"
        fi

        # ツール名をクリーンアップ
        CLEAN_NAME=$(echo "$TITLE" | sed 's/ 要件定義書.*//; s/ 仕様書.*//')

        TOOLS_JSON="$TOOLS_JSON{\"name\":\"$CLEAN_NAME\",\"file\":\"$FILE\",\"done\":$TOOL_DONE,\"total\":$TOOL_TOTAL,\"status\":\"$STATUS\"},"
    done

    TOOLS_JSON="${TOOLS_JSON%,}]"
    PROJECTS_JSON="$PROJECTS_JSON{\"name\":\"$REPO\",\"tools\":$TOOLS_JSON},"

    # コミット取得
    COMMITS=$(gh api "repos/$FULL_REPO/commits?since=${YESTERDAY}T00:00:00Z&per_page=20" \
        --jq '.[] | {sha: .sha[0:7], author: (.author.login // .commit.author.name), message: (.commit.message | split("\n")[0]), date: .commit.author.date}' 2>/dev/null || echo "")

    COMMIT_COUNT=$(echo "$COMMITS" | grep -c '"sha"' 2>/dev/null || echo "0")
    TOTAL_COMMITS=$((TOTAL_COMMITS + COMMIT_COUNT))

    # 各コミットの詳細
    COMMIT_SHAS=$(gh api "repos/$FULL_REPO/commits?since=${YESTERDAY}T00:00:00Z&per_page=10" --jq '.[].sha' 2>/dev/null || echo "")
    for SHA in $COMMIT_SHAS; do
        DETAIL=$(gh api "repos/$FULL_REPO/commits/$SHA" --jq '{author: (.author.login // .commit.author.name), message: (.commit.message | split("\n")[0]), date: .commit.author.date, files: (.files | length), additions: .stats.additions, deletions: .stats.deletions}' 2>/dev/null || echo "")
        if [ -n "$DETAIL" ]; then
            AUTHOR=$(echo "$DETAIL" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['author'])" 2>/dev/null || echo "unknown")
            MSG=$(echo "$DETAIL" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['message'])" 2>/dev/null || echo "")
            DATE=$(echo "$DETAIL" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['date'])" 2>/dev/null || echo "")
            FILES=$(echo "$DETAIL" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['files'])" 2>/dev/null || echo "0")
            ADDS=$(echo "$DETAIL" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['additions'])" 2>/dev/null || echo "0")
            DELS=$(echo "$DETAIL" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['deletions'])" 2>/dev/null || echo "0")
            # Escape quotes in message
            MSG=$(echo "$MSG" | sed 's/"/\\"/g')
            RECENT_COMMITS_JSON="$RECENT_COMMITS_JSON{\"author\":\"$AUTHOR\",\"repo\":\"$REPO\",\"message\":\"$MSG\",\"date\":\"$DATE\",\"files\":$FILES,\"additions\":$ADDS,\"deletions\":$DELS},"
        fi
    done
done

PROJECTS_JSON="${PROJECTS_JSON%,}]"
RECENT_COMMITS_JSON="${RECENT_COMMITS_JSON%,}]"

# 全体進捗率
if [ "$TOTAL_TASKS" -gt 0 ]; then
    TOTAL_PCT=$((TOTAL_DONE * 100 / TOTAL_TASKS))
else
    TOTAL_PCT=0
fi

# メンバー別データ
for MEMBER in $MEMBERS; do
    MEMBER_COMMITS=0
    LAST_PUSH=""
    WORKING_ON="-"

    for REPO in $REPOS; do
        COUNT=$(gh api "repos/$ORG/$REPO/commits?author=$MEMBER&since=${YESTERDAY}T00:00:00Z" --jq 'length' 2>/dev/null || echo "0")
        MEMBER_COMMITS=$((MEMBER_COMMITS + COUNT))
        if [ "$COUNT" -gt 0 ]; then
            WORKING_ON="$REPO"
            LAST_PUSH="$TODAY"
        fi
    done

    # 最終push日（直近が今日でなければ過去を探す）
    if [ -z "$LAST_PUSH" ]; then
        for REPO in $REPOS; do
            LP=$(gh api "repos/$ORG/$REPO/commits?author=$MEMBER&per_page=1" --jq '.[0].commit.author.date // empty' 2>/dev/null || echo "")
            if [ -n "$LP" ]; then
                LAST_PUSH=$(echo "$LP" | cut -dT -f1)
                WORKING_ON="$REPO"
                break
            fi
        done
    fi

    # ステータス判定
    if [ "$MEMBER_COMMITS" -gt 0 ]; then
        M_STATUS="active"
        ACTIVE_COUNT=$((ACTIVE_COUNT + 1))
    elif [ -n "$LAST_PUSH" ]; then
        M_STATUS="warning"
    else
        M_STATUS="inactive"
    fi

    LP_JSON="null"
    [ -n "$LAST_PUSH" ] && LP_JSON="\"$LAST_PUSH\""

    MEMBERS_JSON="$MEMBERS_JSON{\"login\":\"$MEMBER\",\"display\":\"$MEMBER\",\"last_push\":$LP_JSON,\"commits_today\":$MEMBER_COMMITS,\"status\":\"$M_STATUS\",\"working_on\":\"$WORKING_ON\"},"
done

MEMBERS_JSON="${MEMBERS_JSON%,}]"

# アラート生成
INACTIVE_COUNT=$((MEMBER_COUNT - ACTIVE_COUNT))
if [ "$INACTIVE_COUNT" -gt 0 ]; then
    ALERTS_JSON="$ALERTS_JSON{\"type\":\"warning\",\"message\":\"${INACTIVE_COUNT}名が直近2日間pushしていません\"},"
fi
ALERTS_JSON="${ALERTS_JSON%,}]"

# チーム全体ヘルス
if [ "$ACTIVE_COUNT" -ge "$((MEMBER_COUNT / 2 + 1))" ] && [ "$TOTAL_PCT" -ge 0 ]; then
    TEAM_HEALTH="green"
elif [ "$ACTIVE_COUNT" -ge 1 ]; then
    TEAM_HEALTH="yellow"
else
    TEAM_HEALTH="red"
fi

# JSON出力
cat > "$OUTPUT_FILE" << JSONEOF
{
    "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "team_health": "$TEAM_HEALTH",
    "total_progress": { "done": $TOTAL_DONE, "total": $TOTAL_TASKS, "percent": $TOTAL_PCT },
    "active_members": { "active": $ACTIVE_COUNT, "total": $MEMBER_COUNT },
    "recent_commit_count": $TOTAL_COMMITS,
    "alerts": $ALERTS_JSON,
    "projects": $PROJECTS_JSON,
    "members": $MEMBERS_JSON,
    "recent_commits": $RECENT_COMMITS_JSON,
    "weekly_trend": {
        "labels": ["6d前","5d前","4d前","3d前","2d前","昨日","今日"],
        "progress": [$TOTAL_PCT,$TOTAL_PCT,$TOTAL_PCT,$TOTAL_PCT,$TOTAL_PCT,$TOTAL_PCT,$TOTAL_PCT],
        "commits": [0,0,0,0,0,0,$TOTAL_COMMITS]
    }
}
JSONEOF

echo "✅ データ生成完了: $OUTPUT_FILE"
