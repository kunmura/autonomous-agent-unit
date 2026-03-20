#!/bin/bash
# output_validator.sh — Structural validation of task output files
# Zero-token operation: pure bash, no LLM calls.
# Checks that deliverables meet minimum evidence requirements.
#
# Usage: output_validator.sh <member_name>
# Returns: 0 if all DONE tasks pass, 1 if any fail (reverts to NEEDS_EVIDENCE)

MEMBER="${1:?Usage: output_validator.sh <member_name>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

TEAM_DIR="$AAU_PROJECT_ROOT/team"
TASKS_FILE="$TEAM_DIR/$MEMBER/tasks.md"
OUTPUT_DIR="$TEAM_DIR/$MEMBER/output"
VALIDATION_LOG="${AAU_TMP}/${AAU_PREFIX}_validation_${MEMBER}.log"

if [[ ! -f "$TASKS_FILE" ]]; then
    exit 0
fi

FAILED=0
CHECKED=0
VALIDATION_ISSUES=""

# Find DONE tasks and their output files
while IFS= read -r line; do
    # Extract task ID: ### TASK-XXX ... [DONE]
    TASK_ID=$(echo "$line" | grep -oE 'TASK-[0-9]+')
    [[ -z "$TASK_ID" ]] && continue

    CHECKED=$((CHECKED + 1))

    # Find output file for this task
    OUTPUT_FILE=""
    if [[ -d "$OUTPUT_DIR" ]]; then
        OUTPUT_FILE=$(find "$OUTPUT_DIR" -name "${TASK_ID}*" -type f 2>/dev/null | head -1)
    fi

    # --- Check 1: Output file exists ---
    if [[ -z "$OUTPUT_FILE" || ! -f "$OUTPUT_FILE" ]]; then
        VALIDATION_ISSUES="${VALIDATION_ISSUES}\n[FAIL] ${TASK_ID}: 成果物ファイルが見つかりません (${OUTPUT_DIR}/${TASK_ID}_*)"
        FAILED=$((FAILED + 1))
        continue
    fi

    FILE_SIZE=$(wc -c < "$OUTPUT_FILE" 2>/dev/null || echo 0)
    FILE_LINES=$(wc -l < "$OUTPUT_FILE" 2>/dev/null || echo 0)

    # --- Check 2: File is not empty/too short ---
    if [[ "$FILE_SIZE" -lt 200 ]]; then
        VALIDATION_ISSUES="${VALIDATION_ISSUES}\n[FAIL] ${TASK_ID}: 成果物が短すぎます (${FILE_SIZE} bytes)"
        FAILED=$((FAILED + 1))
        continue
    fi

    # --- Check 3: Evidence section exists ---
    HAS_EVIDENCE=0
    if grep -qiE '(情報源|信頼性|出典|参考|Sources|References|Evidence|実行結果|Test Result|PASS|FAIL|テスト結果)' "$OUTPUT_FILE" 2>/dev/null; then
        HAS_EVIDENCE=1
    fi

    if [[ "$HAS_EVIDENCE" -eq 0 ]]; then
        VALIDATION_ISSUES="${VALIDATION_ISSUES}\n[FAIL] ${TASK_ID}: 「情報源と信頼性」または「実行結果」セクションがありません"
        FAILED=$((FAILED + 1))
        continue
    fi

    # --- Check 3b: QA reports must have execution evidence (not just code review) ---
    if [[ "$MEMBER" == "qa" ]]; then
        HAS_EXECUTION=0
        if grep -qiE '(実行コマンド|コマンド実行|npm |npx |playwright|スクリーンショット|screenshot|テスト実行|test run|実行結果|exit code|HTTP [0-9])' "$OUTPUT_FILE" 2>/dev/null; then
            HAS_EXECUTION=1
        fi
        if [[ "$HAS_EXECUTION" -eq 0 ]]; then
            VALIDATION_ISSUES="${VALIDATION_ISSUES}\n[WARN] ${TASK_ID}: QAレポートに実行エビデンスがありません（コードレビューのみ）"
        fi
    fi

    # --- Check 4: Unverified facts are marked ---
    # Check if file contains phone numbers, URLs, or prices without ※未確認 markers
    UNMARKED_FACTS=0

    # Phone numbers (Japanese format: 0X-XXXX-XXXX or 0XX-XXX-XXXX)
    PHONE_COUNT=$(grep -cE '0[0-9]{1,4}-[0-9]{1,4}-[0-9]{3,4}' "$OUTPUT_FILE" 2>/dev/null || true)
    if [[ "$PHONE_COUNT" -gt 0 ]]; then
        # Check if ANY phone number has a verification marker nearby
        VERIFIED_PHONES=$(grep -cE '(※未確認|確認済|WebSearch|公式サイト)' "$OUTPUT_FILE" 2>/dev/null || true)
        if [[ "$VERIFIED_PHONES" -eq 0 ]]; then
            UNMARKED_FACTS=$((UNMARKED_FACTS + PHONE_COUNT))
            VALIDATION_ISSUES="${VALIDATION_ISSUES}\n[WARN] ${TASK_ID}: 電話番号${PHONE_COUNT}件に検証マークなし"
        fi
    fi

    # Specific yen amounts (XXX万円, XX億円)
    YEN_COUNT=$(grep -cE '[0-9,]+[万億]円' "$OUTPUT_FILE" 2>/dev/null || true)
    if [[ "$YEN_COUNT" -gt 5 ]]; then
        # Many financial figures — check for source attribution
        SOURCE_REFS=$(grep -cE '(出典|参考|※|WebSearch|調査|統計)' "$OUTPUT_FILE" 2>/dev/null || true)
        if [[ "$SOURCE_REFS" -lt 2 ]]; then
            VALIDATION_ISSUES="${VALIDATION_ISSUES}\n[WARN] ${TASK_ID}: 金額${YEN_COUNT}件に対し出典が不足 (${SOURCE_REFS}件)"
        fi
    fi

    # --- Check 5: Superseded document warning ---
    # If this task references another TASK-XXX that was a revision, flag it
    if grep -qE 'SUPERSEDED|廃止|旧版' "$OUTPUT_FILE" 2>/dev/null; then
        VALIDATION_ISSUES="${VALIDATION_ISSUES}\n[INFO] ${TASK_ID}: 旧版マークあり（正常）"
    fi

done < <(grep '\[DONE\]' "$TASKS_FILE" 2>/dev/null)

# --- Report ---
{
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] === Validation: $MEMBER ==="
    echo "Checked: $CHECKED tasks, Failed: $FAILED"
    if [[ -n "$VALIDATION_ISSUES" ]]; then
        echo -e "$VALIDATION_ISSUES"
    fi
} >> "$VALIDATION_LOG"

# --- Revert failed tasks to NEEDS_EVIDENCE ---
if [[ "$FAILED" -gt 0 ]]; then
    aau_log "VALIDATION: $FAILED/$CHECKED tasks failed evidence check for $MEMBER"
    aau_jlog "warn" "validation_failed" "\"member\":\"$MEMBER\",\"failed\":$FAILED,\"checked\":$CHECKED"

    # For each failed task, change [DONE] → [NEEDS_EVIDENCE] in tasks.md
    while IFS= read -r line; do
        TASK_ID=$(echo "$line" | grep -oE 'TASK-[0-9]+')
        [[ -z "$TASK_ID" ]] && continue

        OUTPUT_FILE=""
        if [[ -d "$OUTPUT_DIR" ]]; then
            OUTPUT_FILE=$(find "$OUTPUT_DIR" -name "${TASK_ID}*" -type f 2>/dev/null | head -1)
        fi

        SHOULD_REVERT=0

        # Re-run the failure checks
        if [[ -z "$OUTPUT_FILE" || ! -f "$OUTPUT_FILE" ]]; then
            SHOULD_REVERT=1
        elif [[ $(wc -c < "$OUTPUT_FILE" 2>/dev/null || echo 0) -lt 200 ]]; then
            SHOULD_REVERT=1
        elif ! grep -qiE '(情報源|信頼性|出典|参考|Sources|References|Evidence)' "$OUTPUT_FILE" 2>/dev/null; then
            SHOULD_REVERT=1
        fi

        if [[ "$SHOULD_REVERT" -eq 1 ]]; then
            # Replace [DONE] with [NEEDS_EVIDENCE] for this specific task
            if [[ "$AAU_PLATFORM" == "Darwin" ]]; then
                sed -i '' "s/### ${TASK_ID}.*\[DONE\]/### ${TASK_ID} [NEEDS_EVIDENCE]/" "$TASKS_FILE"
            else
                sed -i "s/### ${TASK_ID}.*\[DONE\]/### ${TASK_ID} [NEEDS_EVIDENCE]/" "$TASKS_FILE"
            fi
            aau_log "REVERTED: ${TASK_ID} → [NEEDS_EVIDENCE]"
            aau_jlog "warn" "task_reverted" "\"member\":\"$MEMBER\",\"task\":\"$TASK_ID\""
        fi

    done < <(grep '\[DONE\]' "$TASKS_FILE" 2>/dev/null)
fi

# Return validation result
if [[ "$FAILED" -gt 0 ]]; then
    exit 1
else
    if [[ "$CHECKED" -gt 0 ]]; then
        aau_log "VALIDATION: $CHECKED/$CHECKED tasks passed evidence check"
        aau_jlog "info" "validation_passed" "\"member\":\"$MEMBER\",\"checked\":$CHECKED"
    fi
    exit 0
fi
