#!/bin/bash
# config.sh — aau.yaml loader
# Parses YAML config into shell variables. No external deps (pure awk).
# Usage: source lib/config.sh [/path/to/aau.yaml]

AAU_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

_aau_find_config() {
    local search="$1"
    if [[ -n "$search" && -f "$search" ]]; then
        echo "$search"
        return 0
    fi
    # Search upward from CWD
    local dir="$PWD"
    while [[ "$dir" != "/" ]]; do
        if [[ -f "$dir/aau.yaml" ]]; then
            echo "$dir/aau.yaml"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    return 1
}

_aau_parse_yaml() {
    # Lightweight YAML→shell variable parser (no PyYAML dependency)
    local yaml_file="$1"
    python3 - "$yaml_file" << 'PYEOF'
import sys

def parse_value(v):
    v = v.strip()
    if not v:
        return ''
    for q in ('"', "'"):
        if v.startswith(q) and v.endswith(q):
            return v[1:-1]
    if v.lower() == 'true': return True
    if v.lower() == 'false': return False
    if v.lower() in ('none', 'null'): return ''
    try: return int(v)
    except ValueError: pass
    try: return float(v)
    except ValueError: return v

filepath = sys.argv[1]
with open(filepath) as f:
    lines = f.readlines()

# State
path_stack = []       # [(indent, key), ...]
list_key = None       # full key of current list-of-dicts
list_items = []       # [{k:v, ...}, ...]
list_base_indent = -1
simple_lists = {}     # full_key -> [values]

def current_path():
    return '_'.join(k for _, k in path_stack)

def flush_list():
    global list_key, list_items, list_base_indent
    if list_key and list_items:
        sk = f"AAU_{list_key.upper().replace('-', '_')}"
        print(f'{sk}_COUNT={len(list_items)}')
        for i, item in enumerate(list_items):
            for ik, iv in item.items():
                val = 'true' if iv is True else ('false' if iv is False else iv)
                print(f'{sk}_{i}_{ik.upper().replace("-", "_")}="{val}"')
    list_key = None
    list_items = []
    list_base_indent = -1

for raw in lines:
    line = raw.rstrip()
    stripped = line.lstrip()
    if not stripped or stripped.startswith('#'):
        continue
    indent = len(line) - len(stripped)

    # Pop path stack when indent decreases
    while path_stack and indent <= path_stack[-1][0]:
        path_stack.pop()

    # Flush list if we've left its scope
    if list_key and indent <= list_base_indent:
        flush_list()

    # List item: "- ..."
    if stripped.startswith('- '):
        content = stripped[2:].strip()
        parent = current_path()

        if ':' in content and not content.startswith('"') and not content.startswith("'"):
            # Dict list item: "- name: value"
            if list_key != parent:
                flush_list()
                list_key = parent
                list_base_indent = indent - 2 if path_stack else 0
            k, v = content.split(':', 1)
            list_items.append({k.strip(): parse_value(v.strip())})
        else:
            # Simple list item: "- value"
            if parent not in simple_lists:
                simple_lists[parent] = []
            simple_lists[parent].append(parse_value(content))
        continue

    # Continuation of dict list item (indented key: value under a - item)
    if list_key and list_items and ':' in stripped:
        if indent > list_base_indent + 3:
            k, v = stripped.split(':', 1)
            list_items[-1][k.strip()] = parse_value(v.strip())
            continue

    # Regular "key: value" or "key:" (section)
    if ':' in stripped:
        colon_pos = stripped.index(':')
        key = stripped[:colon_pos].strip()
        value = stripped[colon_pos+1:].strip()

        if not value:
            # Section header
            path_stack.append((indent, key))
        else:
            # Scalar value
            full = current_path()
            full_key = f"{full}_{key}" if full else key
            sk = f"AAU_{full_key.upper().replace('-', '_')}"
            v = parse_value(value)
            if isinstance(v, bool):
                print(f'{sk}="{"true" if v else "false"}"')
            else:
                print(f'{sk}="{v}"')

# Final flush
flush_list()

# Output simple lists
for k, items in simple_lists.items():
    sk = f"AAU_{k.upper().replace('-', '_')}"
    joined = '|'.join(str(x) for x in items)
    print(f'{sk}="{joined}"')
    print(f'{sk}_COUNT={len(items)}')
    for i, item in enumerate(items):
        print(f'{sk}_{i}="{item}"')
PYEOF
}

aau_load_config() {
    local config_file
    config_file="$(_aau_find_config "${1:-}")"
    if [[ $? -ne 0 || -z "$config_file" ]]; then
        echo "ERROR: aau.yaml not found" >&2
        return 1
    fi

    # Export config path and project root
    export AAU_CONFIG_FILE="$config_file"
    export AAU_PROJECT_ROOT="$(dirname "$config_file")"

    # Parse and eval
    eval "$(_aau_parse_yaml "$config_file")"

    # Derive convenience variables
    export AAU_PREFIX="${AAU_RUNTIME_PREFIX:-aau}"
    export AAU_TMP="${AAU_RUNTIME_TMP_DIR:-/tmp}"
    export AAU_CLAUDE="${AAU_RUNTIME_CLAUDE_CLI:-/opt/homebrew/bin/claude}"
    export AAU_MODEL="${AAU_RUNTIME_CLAUDE_MODEL:-claude-sonnet-4-6}"
    export AAU_PERM="${AAU_RUNTIME_PERMISSION_MODE:-bypassPermissions}"

    # Load .env if present (secrets)
    local env_file="$AAU_PROJECT_ROOT/.env"
    if [[ -f "$env_file" ]]; then
        set -a
        source "$env_file"
        set +a
    fi

    return 0
}

# Get team member names as space-separated list
aau_team_members() {
    local count="${AAU_TEAM_MEMBERS_COUNT:-0}"
    local members=""
    for ((i=0; i<count; i++)); do
        local var="AAU_TEAM_MEMBERS_${i}_NAME"
        members="$members ${!var}"
    done
    echo "$members" | xargs  # trim
}

# Get a team member attribute
aau_member_attr() {
    local member="$1" attr="$2"
    local count="${AAU_TEAM_MEMBERS_COUNT:-0}"
    for ((i=0; i<count; i++)); do
        local name_var="AAU_TEAM_MEMBERS_${i}_NAME"
        if [[ "${!name_var}" == "$member" ]]; then
            local attr_var="AAU_TEAM_MEMBERS_${i}_$(echo "$attr" | tr '[:lower:]' '[:upper:]')"
            echo "${!attr_var}"
            return 0
        fi
    done
    return 1
}
