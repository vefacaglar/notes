# Subagent runner helpers for Notes project
# Usage: source .claude/progress/lib.sh && run_subagent <explorer|coder|architect|reviewer> <task_name> <prompt_file>

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROGRESS_DIR="$ROOT_DIR/.claude/progress"
OUT_DIR="$PROGRESS_DIR/out"
mkdir -p "$OUT_DIR"

log_progress() {
  echo "$(date +%H:%M:%S) $2" >> "$PROGRESS_DIR/$1.log"
}

ag_env() {
  local P
  P=$(pgrep -f 'language_server' | head -1)
  if [ -n "$P" ]; then
    export ANTIGRAVITY_LS_ADDRESS=127.0.0.1:$(lsof -nP -iTCP -sTCP:LISTEN -a -p "$P" 2>/dev/null | awk 'NR>1{split($9,a,":"); print a[2]}' | sort -n | tail -1)
    export ANTIGRAVITY_CSRF_TOKEN=$(ps -o args= -p "$P" | sed -n 's/.*--csrf_token[= ]\([^ ]*\).*/\1/p')
  fi
}

# Maps role to required model tier:
# coder     -> flash (Gemini 3.8 Flash)
# explorer  -> flash (Gemini 3.8 Flash)
# reviewer  -> pro   (Gemini 4 Argon)
# architect -> pro   (Gemini 4 Argon)
role_model() {
  case "$1" in
    coder|explorer) echo "flash" ;;
    reviewer|architect) echo "pro" ;;
    *) echo "Unknown role: $1" >&2; return 1 ;;
  esac
}

run_subagent() {
  local role=$1 task=$2 prompt_file=$3
  local model full_prompt cid
  model=$(role_model "$role") || return 1
  full_prompt="$OUT_DIR/${task}.${role}.prompt.txt"

  {
    echo "=== ROLE BRIEF (.agents/agents/${role}.md) ==="
    cat "$ROOT_DIR/.agents/agents/${role}.md"
    echo ""
    echo "=== TASK ==="
    cat "$prompt_file"
  } > "$full_prompt"

  ag_env
  log_progress "$task" "START subagent role=$role model=$model"
  cid=$(~/.gemini/antigravity/bin/agentapi new-conversation --model="$model" --profile="$role" --title="${task}-${role}" "$(cat "$full_prompt")" 2>&1 | tee "$OUT_DIR/${task}.${role}.out" | grep -o '[0-9a-f]\{8\}-[0-9a-f-]\{27,\}' | head -1)
  log_progress "$task" "LAUNCHED role=$role model=$model conversationId=$cid"
  echo "$cid"
}
