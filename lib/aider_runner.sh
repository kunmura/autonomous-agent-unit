#!/bin/bash
# aider_runner.sh — Run agent tasks via aider + Ollama (local LLM)
# Usage: source lib/aider_runner.sh; aau_run_aider <args...>
# Complements aider with: Bash execution, multi-round control, Ollama locking

# Requires: common.sh already sourced

_AIDER_CLI="${AAU_AIDER_CLI:-aider}"
_OLLAMA_LOCK="${AAU_TMP}/${AAU_PREFIX}_ollama.lock"

# ── Ollama exclusive lock (one agent at a time to prevent OOM) ────────────
_aider_acquire_ollama_lock() {
    local max_wait="${1:-600}"
    local waited=0
    while [[ -f "$_OLLAMA_LOCK" ]]; do
        local lock_pid
        lock_pid=$(cat "$_OLLAMA_LOCK" 2>/dev/null)
        if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
            sleep 5
            waited=$((waited + 5))
            if [[ $waited -ge $max_wait ]]; then
                aau_log "aider: ollama lock timeout (${max_wait}s), PID=$lock_pid still holds"
                return 1
            fi
        else
            rm -f "$_OLLAMA_LOCK"
            break
        fi
    done
    echo $$ > "$_OLLAMA_LOCK"
    trap "rm -f '$_OLLAMA_LOCK'" EXIT
    return 0
}

_aider_release_ollama_lock() {
    rm -f "$_OLLAMA_LOCK"
}

# ── Build --file / --read flags from task context ──────────────────────────
_aider_build_file_flags() {
    local member="$1"
    local file_globs="$2"
    local flags=""

    # Always include tasks.md + progress.md as editable
    local tf="team/${member}/tasks.md"
    local pf="team/${member}/progress.md"
    [[ -f "$tf" ]] && flags="$flags --file $tf"
    [[ -f "$pf" ]] && flags="$flags --file $pf"

    # Expand aider_files globs → --file (editable)
    if [[ -n "$file_globs" ]]; then
        IFS=',' read -ra GLOBS <<< "$file_globs"
        for glob in "${GLOBS[@]}"; do
            glob=$(echo "$glob" | xargs) # trim whitespace
            local count=0
            for f in $glob; do
                [[ -f "$f" && $count -lt 20 ]] || continue
                flags="$flags --file $f"
                count=$((count + 1))
            done
        done
    fi

    # Auto-detect files referenced in IN_PROGRESS task body
    if [[ -f "$tf" ]]; then
        local task_files
        task_files=$(python3 -c "
import re, sys
from pathlib import Path
content = Path('$tf').read_text(errors='ignore')
# Find IN_PROGRESS task section
m = re.search(r'^### TASK-\d+.*\[IN_PROGRESS\].*?\n(.*?)(?=^### |\Z)', content, re.MULTILINE | re.DOTALL)
if not m: sys.exit(0)
body = m.group(1)
# Extract file paths (backtick-wrapped or plain paths with extensions)
for p in re.findall(r'\x60([^\x60]+\.\w{1,5})\x60', body):
    if Path(p).exists() and not p.startswith('/'):
        print(p)
" 2>/dev/null)
        while IFS= read -r f; do
            [[ -n "$f" && -f "$f" ]] && flags="$flags --file $f"
        done <<< "$task_files"
    fi

    echo "$flags"
}

# ── Extract shell commands from aider output and execute safe ones ─────────
_aider_extract_and_run_commands() {
    local output="$1"
    local results=""

    local commands
    commands=$(echo "$output" | python3 -c "
import sys, re
text = sys.stdin.read()
cmds = []
# Extract from fenced code blocks (```bash, ```sh, ```shell, or bare ```)
for m in re.finditer(r'\x60\x60\x60(?:bash|sh|shell)?\n(.*?)\x60\x60\x60', text, re.DOTALL):
    for line in m.group(1).strip().splitlines():
        line = line.strip()
        if line and not line.startswith('#') and not line.startswith('//'):
            cmds.append(line)
# Also extract single-line shell suggestions (common aider pattern)
for m in re.finditer(r'^\s*\$ (.+)$', text, re.MULTILINE):
    cmds.append(m.group(1).strip())
# Deduplicate while preserving order
seen = set()
for c in cmds:
    if c not in seen:
        seen.add(c)
        print(c)
" 2>/dev/null)

    [[ -z "$commands" ]] && return

    # Safe command prefixes
    local SAFE_PATTERNS=(
        "npm " "npx " "node " "python3 " "python " "make "
        "cargo " "go " "mkdir " "cp " "mv " "cat " "ls "
        "cd " "grep " "head " "tail " "wc " "sort "
        "chmod " "touch " "echo "
    )
    # Deny patterns
    local DENY_PATTERNS=("rm -rf" "sudo " "curl " "wget " "ssh " "> /dev" "dd " "mkfs")

    while IFS= read -r cmd; do
        [[ -z "$cmd" ]] && continue

        # Check deny list
        local denied=false
        for dp in "${DENY_PATTERNS[@]}"; do
            [[ "$cmd" == *"$dp"* ]] && denied=true && break
        done
        [[ "$denied" == "true" ]] && continue

        # Check safe list
        local safe=false
        for sp in "${SAFE_PATTERNS[@]}"; do
            [[ "$cmd" == "$sp"* ]] && safe=true && break
        done
        [[ "$safe" != "true" ]] && continue

        aau_log "aider: executing suggested command: $cmd"
        local cmd_result
        cmd_result=$(cd "$AAU_PROJECT_ROOT" && eval "$cmd" 2>&1 | tail -50)
        local cmd_exit=$?
        results="${results}\n\$ ${cmd}\n${cmd_result}\n(exit: ${cmd_exit})\n"
    done <<< "$commands"

    echo -e "$results"
}

# ── Main: run aider with multi-round control ───────────────────────────────
# Args: $1=member $2=prompt $3=timeout $4=max_rounds $5=model $6=file_globs $7=outfile
aau_run_aider() {
    local member="$1"
    local prompt="$2"
    local timeout="$3"
    local max_rounds="${4:-3}"
    local model="${5:-ollama_chat/qwen2.5-coder:32b}"
    local file_globs="$6"
    local outfile="$7"

    # Acquire Ollama lock (one agent at a time)
    if ! _aider_acquire_ollama_lock; then
        aau_log "aider: failed to acquire ollama lock"
        echo "ERROR: ollama lock timeout" > "$outfile"
        return 1
    fi

    # Ollama health check
    local ollama_base="${AAU_LOCAL_LLM_URL:-http://localhost:11434/api/generate}"
    ollama_base="${ollama_base%/api/generate}"
    if ! curl -s --max-time 5 "${ollama_base}/api/tags" > /dev/null 2>&1; then
        aau_log "aider: Ollama unreachable at ${ollama_base}"
        _aider_release_ollama_lock
        echo "ERROR: Ollama unreachable" > "$outfile"
        return 1
    fi

    local total_start=$(date +%s)
    local current_prompt="$prompt"
    local round=0
    > "$outfile"

    cd "$AAU_PROJECT_ROOT"

    while [[ $round -lt $max_rounds ]]; do
        round=$((round + 1))
        local elapsed=$(( $(date +%s) - total_start ))
        [[ $elapsed -ge $timeout ]] && {
            aau_log "aider: timeout after ${elapsed}s (round $round/$max_rounds)"
            echo "Session timed out" >> "$outfile"
            break
        }

        local remaining=$(( timeout - elapsed ))
        local file_flags
        file_flags=$(_aider_build_file_flags "$member" "$file_globs")

        aau_log "aider: round $round/$max_rounds (model=$model, remaining=${remaining}s)"

        # Build message file (avoids shell quoting issues with long prompts)
        local msg_file="${AAU_TMP}/${AAU_PREFIX}_aider_msg_${member}_$$.txt"
        echo "$current_prompt" > "$msg_file"

        # Run aider
        local round_out="${outfile}.round${round}"
        local aider_pid
        $_AIDER_CLI \
            --model "$model" \
            --message-file "$msg_file" \
            --no-git --no-auto-commits --yes-always --exit --no-stream \
            --no-show-model-warnings \
            --timeout "${remaining}" \
            $file_flags \
            > "$round_out" 2>&1 &
        aider_pid=$!

        # Watchdog timeout
        (
            sleep "$remaining"
            kill "$aider_pid" 2>/dev/null
        ) &
        local watchdog_pid=$!

        wait "$aider_pid" 2>/dev/null
        local aider_exit=$?
        kill "$watchdog_pid" 2>/dev/null; wait "$watchdog_pid" 2>/dev/null

        rm -f "$msg_file"

        # Append to main output
        cat "$round_out" >> "$outfile" 2>/dev/null
        local round_output
        round_output=$(cat "$round_out" 2>/dev/null)
        rm -f "$round_out"

        aau_log "aider: round $round finished (exit=$aider_exit)"

        # Check if task is done
        if grep -qE '^### TASK-.*\[DONE\]' "team/${member}/tasks.md" 2>/dev/null; then
            local active
            active=$(grep -cE '^### TASK-.*\[(IN_PROGRESS|PENDING|NEEDS_EVIDENCE)\]' "team/${member}/tasks.md" 2>/dev/null || true)
            if [[ "${active:-0}" -eq 0 ]]; then
                aau_log "aider: all tasks completed after round $round"
                break
            fi
        fi

        # Bash補完: extract and run suggested commands
        local cmd_results
        cmd_results=$(_aider_extract_and_run_commands "$round_output")

        if [[ -n "$cmd_results" ]]; then
            echo "$cmd_results" >> "$outfile"
            # Feed results back for next round
            current_prompt="前回の作業の続きです。以下のコマンド実行結果を踏まえて作業を継続してください:
${cmd_results}

team/${member}/tasks.md のIN_PROGRESSタスクの残作業に集中してください。完了したら[DONE]に更新してください。"
        else
            # No commands to run, no more rounds needed
            aau_log "aider: no further commands, ending after round $round"
            break
        fi
    done

    _aider_release_ollama_lock

    # Return appropriate exit code
    if [[ $round -ge $max_rounds ]]; then
        echo "Reached max turns" >> "$outfile"
        return 124
    fi
    return 0
}
