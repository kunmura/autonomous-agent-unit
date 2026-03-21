#!/bin/bash
# schedule.sh — Centralized schedule check for all AAU components
# Usage: source lib/schedule.sh; aau_is_active [component]
# Returns 0 if active, 1 if inactive (quiet/break/weekend-off)
#
# Reads AAU_SCHEDULE_* variables (from aau.yaml schedule: block).
# Falls back to legacy AAU_DIRECTOR_QUIET_HOURS_START/END if schedule not configured.

# Convert "HH:MM" to minutes since midnight
_aau_hhmm_to_min() {
    local t="$1"
    local h="${t%%:*}"
    local m="${t##*:}"
    echo $(( 10#$h * 60 + 10#$m ))
}

# Check if current minutes-since-midnight is within a "HH:MM-HH:MM" range
_aau_in_range() {
    local now_min="$1" range="$2"
    local start_str="${range%%-*}"
    local end_str="${range##*-}"
    local start=$(_aau_hhmm_to_min "$start_str")
    local end=$(_aau_hhmm_to_min "$end_str")
    if [[ "$start" -le "$end" ]]; then
        [[ "$now_min" -ge "$start" && "$now_min" -lt "$end" ]]
    else
        # Overnight range (e.g. 22:00-06:00)
        [[ "$now_min" -ge "$start" || "$now_min" -lt "$end" ]]
    fi
}

# Main function: check if the system should be active now
# Args: [component] — "director" | "agents" | "" (default)
# Returns: 0 = active, 1 = inactive
aau_is_active() {
    local component="${1:-}"
    local tz="${AAU_SCHEDULE_TIMEZONE:-}"
    local now_hhmm now_dow

    # Get current time in configured timezone
    if [[ -n "$tz" ]]; then
        now_hhmm=$(TZ="$tz" date +%H:%M)
        now_dow=$(TZ="$tz" date +%u)  # 1=Mon, 7=Sun
    else
        now_hhmm=$(date +%H:%M)
        now_dow=$(date +%u)
    fi
    local now_min=$(_aau_hhmm_to_min "$now_hhmm")

    # ─── Emergency override ──────────────────────────────────────
    local override_file="${AAU_TMP}/${AAU_PREFIX}_emergency_override"
    if [[ -f "$override_file" ]]; then
        local duration=$(cat "$override_file" 2>/dev/null || echo 3600)
        local file_mtime=$(aau_file_mtime "$override_file")
        local now_epoch=$(date +%s)
        local expires=$(( file_mtime + duration ))
        if [[ "$now_epoch" -lt "$expires" ]]; then
            return 0  # Emergency override active
        else
            rm -f "$override_file"  # Expired
        fi
    fi

    # ─── Determine active_hours for this component ───────────────
    local active_hours="${AAU_SCHEDULE_ACTIVE_HOURS:-}"

    # Weekend check
    if [[ "$now_dow" -ge 6 ]]; then
        local weekend_mode="${AAU_SCHEDULE_WEEKEND_MODE:-normal}"
        case "$weekend_mode" in
            off)
                return 1 ;;
            reduced)
                local weekend_hours="${AAU_SCHEDULE_WEEKEND_ACTIVE_HOURS:-}"
                [[ -n "$weekend_hours" ]] && active_hours="$weekend_hours"
                ;;
            # normal: use weekday active_hours
        esac
    fi

    # Component-level override
    case "$component" in
        director)
            local dir_hours="${AAU_SCHEDULE_OVERRIDES_DIRECTOR_ACTIVE_HOURS:-}"
            [[ -n "$dir_hours" ]] && active_hours="$dir_hours"
            ;;
        agents)
            local agent_hours="${AAU_SCHEDULE_OVERRIDES_AGENTS_ACTIVE_HOURS:-}"
            [[ -n "$agent_hours" ]] && active_hours="$agent_hours"
            ;;
    esac

    # ─── Legacy fallback ─────────────────────────────────────────
    if [[ -z "$active_hours" ]]; then
        local quiet_start="${AAU_DIRECTOR_QUIET_HOURS_START:-0}"
        local quiet_end="${AAU_DIRECTOR_QUIET_HOURS_END:-8}"
        local now_hour="${now_hhmm%%:*}"
        now_hour=$((10#$now_hour))
        if [[ "$now_hour" -ge "$quiet_start" && "$now_hour" -lt "$quiet_end" ]]; then
            return 1
        fi
        return 0
    fi

    # ─── Active hours check ──────────────────────────────────────
    if ! _aau_in_range "$now_min" "$active_hours"; then
        return 1
    fi

    # ─── Breaks check ────────────────────────────────────────────
    local breaks="${AAU_SCHEDULE_BREAKS:-}"
    if [[ -n "$breaks" ]]; then
        IFS='|' read -ra break_list <<< "$breaks"
        for brk in "${break_list[@]}"; do
            brk=$(echo "$brk" | tr -d ' "')
            [[ -z "$brk" ]] && continue
            if _aau_in_range "$now_min" "$brk"; then
                return 1
            fi
        done
    fi

    return 0
}

# Get human-readable schedule status (for logging/debug)
aau_schedule_status() {
    local component="${1:-}"
    if aau_is_active "$component"; then
        echo "ACTIVE"
    else
        echo "QUIET"
    fi
}
