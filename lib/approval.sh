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

    # PPT generation mode: "director" (Claude session) or "auto" (zero-token fallback)
    local ppt_mode="${AAU_APPROVAL_PPT_MODE:-auto}"
    if [[ "$ppt_mode" == "director" ]]; then
        # Director Claude session will create the PPT — just notify
        aau_log "approval PPT deferred to director session: $ap_id"
        aau_notify_flush "承認依頼 ${ap_id}: ${summary} — ディレクターがPPT資料を作成中です。しばらくお待ちください。"
        return 0
    fi

    # Generate PPT (zero-token fallback) — self-contained document with embedded images & reports
    mkdir -p "$(dirname "$ppt_path")"
    python3 - "$ap_id" "$summary" "$context" "$ppt_path" "$AAU_PROJECT_ROOT" << 'PYEOF'
import sys, os, re
from pathlib import Path

ap_id = sys.argv[1]
summary = sys.argv[2]
context = sys.argv[3]
ppt_path = sys.argv[4]
project_root = Path(sys.argv[5])

try:
    from pptx import Presentation
    from pptx.util import Inches, Pt, Emu
    from pptx.enum.text import PP_ALIGN
    from datetime import datetime

    prs = Presentation()
    prs.slide_width = Inches(13.33)
    prs.slide_height = Inches(7.5)
    team_dir = project_root / "team"

    def add_text_slide(title, body_text):
        slide = prs.slides.add_slide(prs.slide_layouts[1])
        slide.shapes.title.text = title
        tf = slide.placeholders[1].text_frame
        tf.clear()
        for i, line in enumerate(body_text.split('\n')[:30]):
            if i == 0:
                tf.paragraphs[0].text = line
                tf.paragraphs[0].font.size = Pt(14)
            else:
                p = tf.add_paragraph()
                p.text = line
                p.font.size = Pt(14)
        return slide

    def add_image_slide(title, image_path, caption=""):
        slide = prs.slides.add_slide(prs.slide_layouts[6])  # blank layout
        # Title
        from pptx.util import Inches, Pt
        txBox = slide.shapes.add_textbox(Inches(0.5), Inches(0.2), Inches(12), Inches(0.6))
        tf = txBox.text_frame
        tf.text = title
        tf.paragraphs[0].font.size = Pt(24)
        tf.paragraphs[0].font.bold = True
        # Image — fit within slide
        try:
            from PIL import Image
            with Image.open(str(image_path)) as img:
                w, h = img.size
            max_w, max_h = 11.5, 5.5
            scale = min(max_w / (w / 96), max_h / (h / 96))
            disp_w = min(w / 96 * scale, max_w)
            disp_h = min(h / 96 * scale, max_h)
        except Exception:
            disp_w, disp_h = 10, 5.5
        left = Inches((13.33 - disp_w) / 2)
        top = Inches(1.0)
        slide.shapes.add_picture(str(image_path), left, top,
                                 Inches(disp_w), Inches(disp_h))
        # Caption
        if caption:
            txBox2 = slide.shapes.add_textbox(Inches(0.5), Inches(6.8), Inches(12), Inches(0.5))
            tf2 = txBox2.text_frame
            tf2.text = caption
            tf2.paragraphs[0].font.size = Pt(12)
        return slide

    # === Slide 1: Title ===
    slide = prs.slides.add_slide(prs.slide_layouts[0])
    slide.shapes.title.text = f"承認依頼: {summary}"
    slide.placeholders[1].text = f"{datetime.now().strftime('%Y-%m-%d')}\n{ap_id}"

    # === Slide 2: Project Status ===
    status_file = team_dir / "director" / "status.md"
    if status_file.exists():
        status_text = status_file.read_text(errors='ignore')[:1500]
        add_text_slide("プロジェクト状況", status_text)

    # === Slide 3: Summary + Context ===
    summary_body = summary
    if context:
        summary_body += f"\n\n{context[:800]}"
    # Add dashboard info if available
    dashboard_file = team_dir / "dashboard.md"
    if dashboard_file.exists():
        try:
            dash = dashboard_file.read_text(errors='ignore')
            # Strip markdown formatting for PPT
            dash_clean = re.sub(r'^[>#\-\s]*$', '', dash, flags=re.MULTILINE)
            dash_clean = re.sub(r'\n{3,}', '\n\n', dash_clean).strip()
            summary_body += f"\n\n--- ダッシュボード ---\n{dash_clean[:600]}"
        except Exception:
            pass
    add_text_slide("概要", summary_body)

    # === Slides 4+: Deliverables linked to recent DONE tasks ===
    # Find DONE task IDs from each member's tasks.md, then include matching outputs
    for member_dir in sorted(team_dir.iterdir()):
        if not member_dir.is_dir() or member_dir.name == "director":
            continue
        out_dir = member_dir / "output"
        tasks_file = member_dir / "tasks.md"
        if not out_dir.exists() or not tasks_file.exists():
            continue

        member_name = member_dir.name.capitalize()

        # Get recent DONE task IDs (last 5)
        done_ids = []
        try:
            for line in tasks_file.read_text(errors='ignore').split('\n'):
                m = re.match(r'^###\s+(TASK-\S+).*\[DONE\]', line)
                if m:
                    done_ids.append(m.group(1))
        except Exception:
            continue
        # Include all DONE tasks — completeness over brevity
        if not done_ids:
            continue

        md_contents = []
        images = []
        other_files = []

        for f in sorted(out_dir.iterdir(), key=lambda x: x.stat().st_mtime, reverse=True):
            if not f.is_file() or f.name.startswith('.'):
                continue
            # Only include files matching a DONE task ID
            if not any(tid in f.name for tid in done_ids):
                continue
            # Skip evidence validation files
            if f.name.endswith('_evidence.md'):
                continue
            ext = f.suffix.lower()
            size_kb = f.stat().st_size / 1024

            if ext in ('.md', '.txt'):
                try:
                    text = f.read_text(errors='ignore')
                    md_contents.append((f.name, text))
                except Exception:
                    pass
            elif ext in ('.png', '.jpg', '.jpeg', '.webp'):
                if size_kb < 10240:
                    images.append(f)
            elif ext in ('.glb', '.gltf', '.obj', '.fbx'):
                other_files.append(f"🎮 {f.name} ({size_kb/1024:.1f}MB 3Dモデル)")
            elif ext in ('.mp4', '.webm'):
                other_files.append(f"🎬 {f.name} ({size_kb/1024:.1f}MB 動画)")
            elif ext not in ('.pptx',):
                other_files.append(f"📎 {f.name} ({size_kb:.0f}KB)")

        if not md_contents and not images and not other_files:
            continue

        # Text reports — 1 report per slide, max 2 slides per report
        for fname, text in md_contents[:3]:
            lines = text.split('\n')
            chunk_size = 25
            for chunk_idx in range(0, min(len(lines), chunk_size * 2), chunk_size):
                chunk = '\n'.join(lines[chunk_idx:chunk_idx + chunk_size])
                if not chunk.strip():
                    continue
                page_label = f" ({chunk_idx // chunk_size + 1})" if len(lines) > chunk_size else ""
                add_text_slide(f"[{member_name}] {fname}{page_label}", chunk)

        # Images — embedded (max 3 per member)
        for img in images[:3]:
            add_image_slide(
                f"[{member_name}] {img.name}",
                img,
                f"{img.stat().st_size / 1024:.0f}KB"
            )

        # Other files
        if other_files:
            add_text_slide(f"[{member_name}] その他の成果物", '\n'.join(other_files))

    # === Final Slide: Approval Request ===
    add_text_slide("承認事項", """以下をSlackでご回答ください：

承認する場合:
  「承認」「進めて」「OK」のいずれか

却下する場合:
  「却下」と理由をお書きください""")

    prs.save(ppt_path)
    print("OK")
except Exception as e:
    import traceback
    traceback.print_exc()
    print(f"ERROR:{e}")
PYEOF

    local ppt_result=$?
    if [[ -f "$ppt_path" ]]; then
        aau_log "approval PPT created: $ppt_path"
    fi

    # Post approval to Slack: text summary + image uploads (no PPT dependency)
    if [[ -n "$SLACK_TOKEN" && -n "$SLACK_CHANNEL" ]]; then
        # Generate rich text summary for Slack (readable without local file access)
        local slack_body
        slack_body=$(python3 - "$AAU_PROJECT_ROOT" "$summary" << 'PYEOF'
import sys
from pathlib import Path

project_root = Path(sys.argv[1])
summary = sys.argv[2]
team_dir = project_root / "team"

parts = [f"*【承認依頼】{summary}*\n"]

# Status summary
status_file = team_dir / "director" / "status.md"
if status_file.exists():
    lines = status_file.read_text().split("\n")
    # Extract key info (phase, active tasks, schedule)
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if any(kw in line for kw in ["フェーズ", "phase", "Phase", "状態", "タスク", "スケジュール", "TASK-"]):
            parts.append(f"  {line}")
    parts.append("")

# Deliverables with content
parts.append("*成果物:*")
for member_dir in sorted(team_dir.iterdir()):
    if not member_dir.is_dir() or member_dir.name == "director":
        continue
    out_dir = member_dir / "output"
    if not out_dir.exists():
        continue
    member_outputs = []
    for f in sorted(out_dir.iterdir()):
        if not f.is_file() or f.name.startswith('.'):
            continue
        ext = f.suffix.lower()
        size_kb = f.stat().st_size / 1024
        if ext in ('.md', '.txt'):
            try:
                text = f.read_text(errors='ignore')
                content_lines = [l.strip() for l in text.split('\n')
                                if l.strip() and not l.startswith('#') and not l.startswith('---')][:3]
                desc = ' '.join(content_lines)[:150]
                member_outputs.append(f"  📄 {f.name}: {desc}")
            except Exception:
                member_outputs.append(f"  📄 {f.name} ({size_kb:.0f}KB)")
        elif ext in ('.png', '.jpg', '.jpeg', '.gif', '.webp'):
            member_outputs.append(f"  🖼 {f.name} ({size_kb:.0f}KB) — 画像は別途アップロード")
        elif ext in ('.glb', '.gltf', '.obj', '.fbx'):
            member_outputs.append(f"  🎮 {f.name} ({size_kb/1024:.1f}MB 3Dモデル)")
        elif ext in ('.mp4', '.webm'):
            member_outputs.append(f"  🎬 {f.name} ({size_kb/1024:.1f}MB 動画)")
        elif ext in ('.pptx',):
            pass  # Skip approval PPTs themselves
        else:
            member_outputs.append(f"  📎 {f.name} ({size_kb:.0f}KB)")
    if member_outputs:
        parts.append(f"[{member_dir.name}]")
        parts.extend(member_outputs[-8:])

parts.append("")
parts.append("承認 → 「承認」「進めて」「OK」のいずれかをご返信ください")
parts.append("却下 → 「却下」と理由をお伝えください")

print("\n".join(parts))
PYEOF
        )

        # Post text summary
        python3 -c "
import requests, json, sys
token = sys.argv[1]
channel = sys.argv[2]
text = sys.argv[3]
resp = requests.post('https://slack.com/api/chat.postMessage',
    headers={'Authorization': f'Bearer {token}', 'Content-Type': 'application/json'},
    json={'channel': channel, 'text': text})
print('OK' if resp.json().get('ok') else f'ERROR: {resp.text}')
" "$SLACK_TOKEN" "$SLACK_CHANNEL" "$slack_body" 2>/dev/null
        aau_log "approval summary posted to Slack: $ap_id"

        # Upload PPT to Slack
        if [[ -f "$ppt_path" ]]; then
            local ppt_size
            ppt_size=$(stat -f%z "$ppt_path" 2>/dev/null || stat -c%s "$ppt_path" 2>/dev/null)
            local ppt_name
            ppt_name=$(basename "$ppt_path")
            local ppt_resp
            ppt_resp=$(curl -s -X POST 'https://slack.com/api/files.getUploadURLExternal' \
                -H "Authorization: Bearer ${SLACK_TOKEN}" \
                -H 'Content-Type: application/x-www-form-urlencoded' \
                -d "filename=${ppt_name}&length=${ppt_size}")
            local ppt_url ppt_fid
            ppt_url=$(echo "$ppt_resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('upload_url',''))" 2>/dev/null)
            ppt_fid=$(echo "$ppt_resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('file_id',''))" 2>/dev/null)
            if [[ -n "$ppt_url" && -n "$ppt_fid" ]]; then
                curl -s -X POST "$ppt_url" -F "file=@${ppt_path}" > /dev/null 2>&1
                curl -s -X POST 'https://slack.com/api/files.completeUploadExternal' \
                    -H "Authorization: Bearer ${SLACK_TOKEN}" \
                    -H 'Content-Type: application/json' \
                    -d "{\"files\":[{\"id\":\"${ppt_fid}\",\"title\":\"承認資料\"}],\"channel_id\":\"${SLACK_CHANNEL}\"}" > /dev/null 2>&1
                aau_log "approval PPT uploaded to Slack: $ap_id"
            fi
        fi

        # Upload output images directly to Slack (max 5, most recent first)
        local img_count=0
        local img_max=5
        for member in $(aau_team_members); do
            [[ "$member" == "director" ]] && continue
            local out_dir="$AAU_PROJECT_ROOT/team/$member/output"
            [[ -d "$out_dir" ]] || continue
            for img in $(ls -t "$out_dir"/*.png "$out_dir"/*.jpg "$out_dir"/*.gif 2>/dev/null); do
                [[ "$img_count" -ge "$img_max" ]] && break 2
                local img_size
                img_size=$(stat -f%z "$img" 2>/dev/null || stat -c%s "$img" 2>/dev/null)
                # Skip very large files (>10MB)
                [[ "$img_size" -gt 10485760 ]] && continue
                local img_name
                img_name=$(basename "$img")
                local img_resp
                img_resp=$(curl -s -X POST 'https://slack.com/api/files.getUploadURLExternal' \
                    -H "Authorization: Bearer ${SLACK_TOKEN}" \
                    -H 'Content-Type: application/x-www-form-urlencoded' \
                    -d "filename=${img_name}&length=${img_size}")
                local img_url img_fid
                img_url=$(echo "$img_resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('upload_url',''))" 2>/dev/null)
                img_fid=$(echo "$img_resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('file_id',''))" 2>/dev/null)
                if [[ -n "$img_url" && -n "$img_fid" ]]; then
                    curl -s -X POST "$img_url" -F "file=@${img}" > /dev/null 2>&1
                    curl -s -X POST 'https://slack.com/api/files.completeUploadExternal' \
                        -H "Authorization: Bearer ${SLACK_TOKEN}" \
                        -H 'Content-Type: application/json' \
                        -d "{\"files\":[{\"id\":\"${img_fid}\",\"title\":\"${img_name}\"}],\"channel_id\":\"${SLACK_CHANNEL}\"}" > /dev/null 2>&1
                    img_count=$((img_count + 1))
                    aau_log "approval image uploaded: $img_name"
                fi
            done
        done
        aau_jlog "info" "approval_posted" "\"id\":\"$ap_id\",\"images\":$img_count"
    else
        aau_notify_flush "${summary} — Slack未設定のため手動確認してください"
    fi
}
