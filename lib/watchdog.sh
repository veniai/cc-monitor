#!/usr/bin/env bash
# Watchdog: detect stuck Claude Code sessions

[[ -n "${_WATCHDOG_LOADED:-}" ]] && return 0
_WATCHDOG_LOADED=1

handle_watchdog() {
  local session pane_id pane_text spinner_line token_raw token_norm
  local prev_token first_seen now count wait_raw wait_secs
  local wait_indicator

  while read -r session pane_id; do
    [[ -z "$session" ]] && continue

    local marker
    marker=$(marker_path "$session")

    # Only capture visible screen — scrollback may contain stale spinners
    pane_text=$(capture_pane "$pane_id")

    # Match CC spinner: exact 7 icons [·✢✳✶✻✽*] + verb + … + (time
    spinner_line=$(echo "$pane_text" | grep -P '^[·✢✳✶✻✽*].{0,80}…\s*\(\d+[hms]' | tail -1)
    token_raw=$(echo "$spinner_line" | grep -oP '[\d.]+[kK]?(?=\s*tokens?)' | tail -1)

    now=$(date +%s)

    # --- Quota suppress: skip recovery until reset time ---
    local quota_resets_at
    quota_resets_at=$(marker_read "$session" "quota_resets_at")
    if [[ -n "$quota_resets_at" && "$quota_resets_at" != "null" && "$quota_resets_at" != "" ]]; then
      if (( now < quota_resets_at )); then
        continue
      fi
      # Quota expired — recover directly
      marker_update "$session" "del(.quota_resets_at) | .auto_recovery_count = 0 | .screen_md5_stable_count = 0 | .token_first_seen_at = $now"
      if is_claude_alive "$pane_id"; then
        recover_session "$pane_id"
        notify_user \
          "**[Monitor]** $session 限额已恢复，已自动重试" \
          "$session ✓ 限额恢复，已重试"
      else
        notify_user \
          "**[Monitor]** $session 限额已恢复，但进程已退出，请手动检查" \
          "$session ⚠ 限额恢复但进程退出"
      fi
      continue
    fi

    local use_md5_fallback=true

    if [[ -n "$spinner_line" ]]; then
      # Spinner detected: task is running, ensure marker
      marker_ensure "$session"
      use_md5_fallback=false

      if [[ -n "$token_raw" ]]; then
        # --- Token-based detection ---
        if [[ "$token_raw" == *[kK] ]]; then
          token_norm=$(echo "${token_raw%[kK]}" | awk '{printf "%.0f", $1 * 1000}')
        else
          token_norm=$(printf '%.0f' "$token_raw")
        fi

        prev_token=$(marker_read "$session" "last_tokens")

        if [[ -z "$prev_token" || "$prev_token" != "$token_norm" ]]; then
          marker_update "$session" ".last_tokens = $token_norm | .token_first_seen_at = $now | .auto_recovery_count = 0 | .screen_md5_stable_count = 0 | .stop_seen = false"
          continue
        fi

        first_seen=$(marker_read "$session" "token_first_seen_at") || first_seen=0
        (( now - first_seen < 1200 )) && continue

        wait_indicator=$(echo "$spinner_line" | grep -oP '\(\K\d+(h\s+\d+)?m\s+\d+s' | head -1)
        if [[ -z "$wait_indicator" ]]; then
          marker_update "$session" ".token_first_seen_at = $now"
          continue
        fi

        _watchdog_recover "$session" "$pane_id" "spinner token 20min unchanged"
      else
        # --- No tokens: check spinner wait time ---
        # Support both "(1m 30s)" and "(thought for 2s)" formats
        wait_raw=$(echo "$spinner_line" | grep -oP '(\(\K\d+(h\s+\d+)?m\s+\d+s|for\s+\K\d+h(\s+\d+m)?\s*\d*s|for\s+\K\d+m\s+\d+s|for\s+\K\d+s)' | head -1)
        if [[ -n "$wait_raw" ]]; then
          wait_secs=$(echo "$wait_raw" | awk '{
            h=0; m=0; s=0;
            for(i=1;i<=NF;i++){
              if($i~/h/) h=$i+0; else if($i~/m/) m=$i+0; else if($i~/s/) s=$i+0;
            }
            print h*3600+m*60+s
          }')
          if (( wait_secs >= 1200 )); then
            _watchdog_recover "$session" "$pane_id" "spinner wait ${wait_raw}"
          fi
        else
          # Spinner present but no tokens and no parseable wait time
          # (e.g. "thought for 2s" where time is stale/unparseable)
          # Fall through to MD5 check
          use_md5_fallback=true
        fi
      fi
    fi

    # --- MD5 fallback: no actionable spinner ---
    if $use_md5_fallback; then
      # Skip if no marker file — never started a task, idle pane
      [[ ! -f "$marker" ]] && continue

      # Skip if task completed normally (Stop hook set stop_seen=true)
      local stop_seen
      stop_seen=$(marker_read "$session" "stop_seen") || stop_seen="false"
      [[ "$stop_seen" == "true" ]] && continue

      local screen_md5 prev_md5 stable_count
      # Strip dynamic UI elements before hashing:
      # - Spinner lines (animated icons ·✢✳✶✻✽*)
      # - Agent expand/collapse toggles (●/spaces)
      screen_md5=$(printf '%s' "$pane_text" | grep -vP '^[·✢✳✶✻✽*]' | grep -vP '^\s*(●|  )Agent\(' | md5sum | awk '{print $1}')
      prev_md5=$(marker_read "$session" "screen_md5") || prev_md5=""

      if [[ "$screen_md5" == "$prev_md5" ]]; then
        # Screen unchanged
        stable_count=$(marker_read "$session" "screen_md5_stable_count") || stable_count=0
        (( stable_count++ ))
        # 4 consecutive unchanged checks (~20 min at 5min interval)
        if (( stable_count >= 4 )); then
          _watchdog_recover "$session" "$pane_id" "screen frozen (MD5 unchanged x${stable_count})"
          marker_update "$session" ".screen_md5_stable_count = 0"
        else
          marker_update "$session" ".screen_md5 = \"$screen_md5\" | .screen_md5_stable_count = $stable_count"
        fi
      else
        # Screen changed — reset
        marker_update "$session" ".screen_md5 = \"$screen_md5\" | .screen_md5_stable_count = 0"
      fi
    fi
  done < <(list_claude_panes)
}

# Shared recovery logic: notify or auto-recover
_watchdog_recover() {
  local session="$1" pane_id="$2" reason="$3"
  local count now
  now=$(date +%s)
  count=$(marker_read "$session" "auto_recovery_count") || count=0

  if (( count >= AUTO_RECOVERY_MAX )); then
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
      echo "[DRY-RUN] $session 已恢复2次未生效 ($reason)"
    else
      notify_user \
        "**[Monitor]** $session 连续2次恢复未生效 ($reason)，请手动检查" \
        "$session ⚠ 自动恢复失败"
      marker_update "$session" ".token_first_seen_at = $now"
    fi
  elif [[ "${DRY_RUN:-false}" == "true" ]]; then
    echo "[DRY-RUN] $session 应执行恢复 ($reason, 第$((count + 1))次)"
  else
    recover_session "$pane_id"
    marker_update "$session" ".auto_recovery_count = ($count + 1) | .token_first_seen_at = $now"
  fi
}
