#!/usr/bin/env bash
# config.sh — INI config loader with env var override for cc-monitor
[[ -n "${_CONFIG_LOADED:-}" ]] && return 0
_CONFIG_LOADED=1

declare -gA _CFG=()

# Resolve config file path: CC_MONITOR_CONFIG > ~/.config/cc-monitor/config.conf > <script_dir>/config.example.conf
_config_resolve_path() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    if [[ -n "${CC_MONITOR_CONFIG:-}" && -f "$CC_MONITOR_CONFIG" ]]; then
        CONFIG_FILE="$CC_MONITOR_CONFIG"
    elif [[ -f "$HOME/.config/cc-monitor/config.conf" ]]; then
        CONFIG_FILE="$HOME/.config/cc-monitor/config.conf"
    else
        CONFIG_FILE="$script_dir/../config.example.conf"
    fi
}

# Parse INI file into _CFG associative array
# Section [foo:bar] + key=baz => _CFG[foo:bar:baz]="value"
_config_parse_ini() {
    local section=""
    local line key value env_name

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Trim leading/trailing whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"

        # Skip blanks and comments
        [[ -z "$line" || "$line" == \#* ]] && continue

        # Section header: [section] or [section:subsection]
        if [[ "$line" =~ ^\[([^]]+)\]$ ]]; then
            section="${BASH_REMATCH[1]}"
            continue
        fi

        # Key=value — split on first '=' only
        if [[ "$line" == *=* ]]; then
            key="${line%%=*}"
            value="${line#*=}"

            # Trim whitespace around key
            key="${key#"${key%%[![:space:]]*}"}"
            key="${key%"${key##*[![:space:]]}"}"

            if [[ -n "$section" ]]; then
                _CFG["${section}:${key}"]="$value"
            else
                _CFG["$key"]="$value"
            fi
        fi
    done < "$CONFIG_FILE"
}

# Apply env var overrides: CC_MONITOR_<SECTION>_<KEY> (uppercase, colon→underscore)
_config_apply_env() {
    local k env_name
    for k in "${!_CFG[@]}"; do
        env_name="CC_MONITOR_${k}"
        env_name="${env_name//-/_}"
        env_name="${env_name//:/_}"
        env_name="${env_name^^}"
        if [[ -n "${!env_name+x}" ]]; then
            _CFG["$k"]="${!env_name}"
        fi
    done
}

# Export commonly used values as globals
_config_export_globals() {
    CC_MODE="$(config_get "monitor:mode" "direct")"
    MARKER_DIR="$(config_get "monitor:marker_dir" "/tmp/cc-monitor")"
    WATCHDOG_INTERVAL="$(config_get "monitor:watchdog_interval" "300")"
    AUTO_RECOVERY_MAX="$(config_get "monitor:auto_recovery_max" "2")"
    SAFE_TOOLS_LIST="$(config_get "monitor:safe_tools" "Read,Glob,Grep")"
    DEBUG_MODE="$(config_get "monitor:debug" "false")"

    export CC_MODE MARKER_DIR WATCHDOG_INTERVAL AUTO_RECOVERY_MAX SAFE_TOOLS_LIST DEBUG_MODE
}

# Main entry: load config once
config_load() {
    _config_resolve_path
    _config_parse_ini
    _config_apply_env
    _config_export_globals
}

# Read any config value: config_get "section:key" "default_value"
config_get() {
    local lookup="${1:-}"
    local default="${2:-}"

    if [[ -v "_CFG[$lookup]" ]]; then
        printf '%s' "${_CFG[$lookup]}"
    else
        printf '%s' "$default"
    fi
}

# Validate required fields for enabled channels
config_validate() {
    local mode errors=0
    mode="$(config_get "monitor:mode" "direct")"

    # dingtalk — 两个模式都需要 webhook
    local enabled webhook
    enabled="$(config_get "channel:dingtalk:enabled" "false")"
    if [[ "$enabled" == "true" ]]; then
        webhook="$(config_get "channel:dingtalk:webhook" "")"
        if [[ -z "$webhook" ]]; then
            echo "[WARN] channel:dingtalk enabled but 'webhook' is empty" >&2
            ((errors++))
        fi
    fi

    if [[ "$mode" == "direct" ]]; then
        # 直连模式：feishu 用 webhook
        enabled="$(config_get "channel:feishu:enabled" "false")"
        if [[ "$enabled" == "true" ]]; then
            webhook="$(config_get "channel:feishu:webhook" "")"
            if [[ -z "$webhook" ]]; then
                echo "[WARN] channel:feishu enabled but 'webhook' is empty" >&2
                ((errors++))
            fi
        fi
    elif [[ "$mode" == "openclaw" ]]; then
        # 龙虾模式：wechat / feishu-openclaw 需要 openclaw 配置
        enabled="$(config_get "channel:wechat:enabled" "false")"
        if [[ "$enabled" == "true" ]]; then
            if [[ -z "$(config_get "channel:wechat:openclaw_account" "")" ]]; then
                echo "[WARN] channel:wechat enabled but 'openclaw_account' is empty" >&2
                ((errors++))
            fi
            if [[ -z "$(config_get "channel:wechat:openclaw_target" "")" ]]; then
                echo "[WARN] channel:wechat enabled but 'openclaw_target' is empty" >&2
                ((errors++))
            fi
        fi
        enabled="$(config_get "channel:feishu-openclaw:enabled" "false")"
        if [[ "$enabled" == "true" ]]; then
            if [[ -z "$(config_get "channel:feishu-openclaw:openclaw_account" "")" ]]; then
                echo "[WARN] channel:feishu-openclaw enabled but 'openclaw_account' is empty" >&2
                ((errors++))
            fi
            if [[ -z "$(config_get "channel:feishu-openclaw:openclaw_target" "")" ]]; then
                echo "[WARN] channel:feishu-openclaw enabled but 'openclaw_target' is empty" >&2
                ((errors++))
            fi
        fi
    else
        echo "[ERROR] Unknown mode '$mode' — must be 'direct' or 'openclaw'" >&2
        ((errors++))
    fi

    return "$errors"
}
