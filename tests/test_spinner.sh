#!/usr/bin/env bash
# Test: spinner regex detection

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/config.sh" 2>/dev/null
source "$SCRIPT_DIR/../lib/tmux.sh" 2>/dev/null

SPINNER_REGEX='^[·✢✳✶✻✽*].{0,80}…\s*\(\d+[hms]'

pass=0
fail=0

assert_match() {
  local label="$1" text="$2"
  if echo "$text" | grep -Pq "$SPINNER_REGEX"; then
    ((pass++))
  else
    echo "FAIL (should match): $label"
    echo "  text: $text"
    ((fail++))
  fi
}

assert_nomatch() {
  local label="$1" text="$2"
  if echo "$text" | grep -Pq "$SPINNER_REGEX"; then
    echo "FAIL (should NOT match): $label"
    echo "  text: $text"
    ((fail++))
  else
    ((pass++))
  fi
}

# Active spinners — should match
assert_match "standard spinner" '✶ TaskName… (5m 30s · ↓ 2.3k tokens)'
assert_match "short time" '· Thinking… (30s)'
assert_match "hours" '✢ Running… (1h 2m 3s)'
assert_match "minutes only" '✳ Testing… (12m 5s)'
assert_match "asterisk icon" '* Building… (3m 12s)'
assert_match "token no decimal" '✻ Processing… (5m 1s · ↓ 1500 tokens)'
assert_match "long description" '✶ Implementing authentication module with OAuth2… (8m 45s)'
assert_match "h only" '✽ Waiting… (1h 0s)'

# Non-spinners — should NOT match
assert_nomatch "indented output" '  some indented output text'
assert_nomatch "completed spinner" '✻ Completed for 5m 30s'
assert_nomatch "prompt" '❯ prompt'
assert_nomatch "random log" 'random log output here'
assert_nomatch "no ellipsis" '✶ Running (5m 30s)'
assert_nomatch "no parens time" '✶ Running… some text'
assert_nomatch "empty line" ''
assert_nomatch "token without spinner" '2.3k tokens'

echo ""
echo "Results: $pass passed, $fail failed"
[[ $fail -eq 0 ]] && exit 0 || exit 1
