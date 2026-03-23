#!/bin/bash
# approval.sh — ID-based approval system with zero-token PPT generation
# Usage: source lib/approval.sh
# Functions: aau_create_approval, aau_check_approval, aau_next_approval_id

# Requires: common.sh already sourced

_AAU_APPROVALS_FILE="$AAU_PROJECT_ROOT/team/director/approvals.md"

# Get next approval ID (AP-001, AP-002, etc.)
aau_next_approval_id() {
    if [[ ! -f "$_AAU_APPROVALS_FILE" ]]; then
        echo "AP-001"
        return
    fi
    local max_num
    max_num=$(grep -oE 'AP-([0-9]+)' "$_AAU_APPROVALS_FILE" | grep -oE '[0-9]+' | sort -n | tail -1)
    if [[ -z "$max_num" ]]; then
        echo "AP-001"
    else
        printf "AP-%03d" $(( max_num + 1 ))
    fi
}

# Check if any approval is pending
# Returns: 0 if pending exists, 1 if all clear
aau_check_approval() {
    [[ -f "$_AAU_APPROVALS_FILE" ]] && grep -q '^status: PENDING' "$_AAU_APPROVALS_FILE" 2>/dev/null
}

# Create approval request: write to approvals.md, generate PPT, upload to Slack
# Args: $1=summary $2=context (optional details for PPT)
aau_create_approval() {
    local summary="$1"
    local context="${2:-}"
    local ap_id
    ap_id=$(aau_next_approval_id)
    local now
    now=$(date '+%Y-%m-%d %H:%M')
    local ppt_path="$AAU_PROJECT_ROOT/team/director/output/${ap_id}_approval.pptx"

    # Ensure approvals.md exists
    if [[ ! -f "$_AAU_APPROVALS_FILE" ]]; then
        echo "# Approvals" > "$_AAU_APPROVALS_FILE"
    fi

    # Append PENDING entry
    cat >> "$_AAU_APPROVALS_FILE" << EOF

## ${ap_id} ${summary}
status: PENDING
created: ${now}
ppt: ${ppt_path}
summary: ${summary}
EOF

    aau_log "approval created: ${ap_id} — ${summary}"
    aau_jlog "info" "approval_created" "\"id\":\"$ap_id\",\"summary\":\"${summary:0:60}\""

    # Generate PPT (zero-token)
    mkdir -p "$(dirname "$ppt_path")"
    python3 - "$ap_id" "$summary" "$context" "$ppt_path" "$AAU_PROJECT_ROOT" << 'PYEOF'
import sys
from pathlib import Path

ap_id = sys.argv[1]
summary = sys.argv[2]
context = sys.argv[3]
ppt_path = sys.argv[4]
project_root = Path(sys.argv[5])

try:
    from pptx import Presentation
    from pptx.util import Inches, Pt
    from pptx.enum.text import PP_ALIGN
    from datetime import datetime

    prs = Presentation()
    prs.slide_width = Inches(13.33)
    prs.slide_height = Inches(7.5)

    # Slide 1: Title
    slide = prs.slides.add_slide(prs.slide_layouts[0])
    slide.shapes.title.text = f"{ap_id}: 承認依頼"
    slide.placeholders[1].text = f"{summary}\n\n{datetime.now().strftime('%Y-%m-%d')}"

    # Slide 2: Summary
    slide = prs.slides.add_slide(prs.slide_layouts[1])
    slide.shapes.title.text = "概要"
    body = slide.placeholders[1]
    body.text = summary
    if context:
        body.text += f"\n\n{context[:500]}"

    # Slide 3: Deliverables
    slide = prs.slides.add_slide(prs.slide_layouts[1])
    slide.shapes.title.text = "成果物"
    body = slide.placeholders[1]
    # List output files from team/*/output/
    outputs = []
    team_dir = project_root / "team"
    for member_dir in sorted(team_dir.iterdir()):
        if not member_dir.is_dir():
            continue
        out_dir = member_dir / "output"
        if out_dir.exists():
            for f in sorted(out_dir.iterdir()):
                if f.is_file() and not f.name.startswith('.'):
                    outputs.append(f"{member_dir.name}/{f.name}")
    body.text = "\n".join(outputs[-15:]) if outputs else "(成果物なし)"

    # Slide 4: Approval request
    slide = prs.slides.add_slide(prs.slide_layouts[1])
    slide.shapes.title.text = "承認事項"
    body = slide.placeholders[1]
    body.text = f"""以下をSlackでご回答ください：

承認する場合:
  {ap_id} 承認

却下する場合:
  {ap_id} 却下 理由: (理由をお書きください)

※ {ap_id} を必ず含めてください"""

    prs.save(ppt_path)
    print("OK")
except Exception as e:
    print(f"ERROR:{e}")
PYEOF

    local ppt_result=$?
    if [[ -f "$ppt_path" ]]; then
        aau_log "approval PPT created: $ppt_path"

        # Upload PPT to Slack
        if [[ -n "$SLACK_TOKEN" && -n "$SLACK_CHANNEL" ]]; then
            local upload_msg="${ap_id}: ${summary}

承認する場合 → 「${ap_id} 承認」
却下する場合 → 「${ap_id} 却下 理由: ...」
とSlackに投稿してください。"

            curl -s -F "file=@${ppt_path}" \
                -F "channels=${SLACK_CHANNEL}" \
                -F "initial_comment=${upload_msg}" \
                -H "Authorization: Bearer ${SLACK_TOKEN}" \
                https://slack.com/api/files.upload > /dev/null 2>&1

            aau_log "approval PPT uploaded to Slack: $ap_id"
            aau_jlog "info" "approval_ppt_uploaded" "\"id\":\"$ap_id\""
        else
            aau_notify_flush "${ap_id}: ${summary} — PPT作成済み（Slack未設定のため手動確認してください）"
        fi
    else
        aau_log "approval PPT generation failed for $ap_id"
        aau_notify_flush "${ap_id}: ${summary} — PPT生成に失敗しましたが、承認依頼は作成済みです。「${ap_id} 承認」でSlackから承認できます。"
    fi
}
