#!/usr/bin/env bash
# Marker file management for cc-monitor

[[ -n "${_MARKER_LOADED:-}" ]] && return 0
_MARKER_LOADED=1

# Resolve marker file path for a session
marker_path() {
  local session="${1:?session name required}"
  printf '%s/%s.json' "${MARKER_DIR:-/tmp/cc-monitor}" "$session"
}

# Create marker with initial JSON
marker_create() {
  local session="${1:?session name required}"
  local target="${2:-}"
  local extra="${3:-}"
  local file
  file=$(marker_path "$session")
  mkdir -p "$(dirname "$file")"
  local now
  now=$(date +%s)
  printf '{"target":"%s","created_at":%d,"auto_recovery_count":0%s}' \
    "$target" "$now" "$extra" > "$file"
}

# Atomic update: apply jq filter to marker
marker_update() {
  local session="${1:?session name required}"
  local filter="${2:?jq filter required}"
  local file
  file=$(marker_path "$session")
  jq "$filter" "$file" > "${file}.tmp" 2>/dev/null && mv "${file}.tmp" "$file"
}

# Read a field from marker
marker_read() {
  local session="${1:?session name required}"
  local field="${2:?field name required}"
  local file
  file=$(marker_path "$session")
  jq -r ".${field} // \"\"" "$file" 2>/dev/null
}

# Remove marker file
marker_cleanup() {
  local session="${1:?session name required}"
  rm -f "$(marker_path "$session")"
}

# Ensure marker exists; fix corrupt JSON
marker_ensure() {
  local session="${1:?session name required}"
  local target="${2:-}"
  local file
  file=$(marker_path "$session")

  if [[ -f "$file" ]]; then
    if ! jq -e '.' "$file" >/dev/null 2>&1; then
      marker_create "$session" "$target"
    fi
  else
    marker_create "$session" "$target"
  fi
}
