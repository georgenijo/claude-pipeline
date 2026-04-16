#!/usr/bin/env bash
# Pipeline JSON event logging

PIPELINE_LOGS_ROOT="$HOME/Documents/pipeline-logs"

init_log() {
  local project="$1" issue="$2"
  LOG_DIR="$PIPELINE_LOGS_ROOT/$project/issue-$issue"
  LOG_FILE="$LOG_DIR/pipeline.json"
  mkdir -p "$LOG_DIR"

  if [ ! -f "$LOG_FILE" ]; then
    cat > "$LOG_FILE" <<JSONEOF
{
  "project": "$project",
  "issue": $issue,
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "status": "running",
  "current_step": null,
  "completed_steps": [],
  "agents": [],
  "pr_number": null,
  "branch": null,
  "error": null
}
JSONEOF
  fi
}

log_agent_start() {
  local agent="$1"
  local iteration="${2:-1}"
  local tmp=$(mktemp)

  jq --arg agent "$agent" \
     --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     --argjson iter "$iteration" \
     '.current_step = $agent |
      .agents += [{
        "name": $agent,
        "iteration": $iter,
        "started_at": $time,
        "ended_at": null,
        "exit_code": null,
        "duration_sec": null
      }]' "$LOG_FILE" > "$tmp" && mv "$tmp" "$LOG_FILE"
}

log_agent_end() {
  local agent="$1" exit_code="$2"
  local tmp=$(mktemp)
  local end_time
  end_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  jq --arg agent "$agent" \
     --arg time "$end_time" \
     --argjson rc "$exit_code" \
     '(.agents | last | select(.name == $agent)) |= (
        .ended_at = $time |
        .exit_code = $rc
      ) |
      if $rc == 0 then
        .completed_steps += [$agent]
      else . end' "$LOG_FILE" > "$tmp" && mv "$tmp" "$LOG_FILE"
}

log_step_artifact() {
  local agent="$1" artifact="$2"
  local tmp=$(mktemp)

  jq --arg agent "$agent" \
     --arg artifact "$artifact" \
     '(.agents | last | select(.name == $agent)) |= (
        .artifacts = ((.artifacts // []) + [$artifact])
      )' "$LOG_FILE" > "$tmp" && mv "$tmp" "$LOG_FILE"
}

log_pipeline_end() {
  local status="$1"
  local tmp=$(mktemp)

  jq --arg status "$status" \
     --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     '.status = $status | .ended_at = $time' "$LOG_FILE" > "$tmp" && mv "$tmp" "$LOG_FILE"
}

log_pr() {
  local pr_number="$1" branch="$2"
  local tmp=$(mktemp)

  jq --argjson pr "$pr_number" \
     --arg branch "$branch" \
     '.pr_number = $pr | .branch = $branch' "$LOG_FILE" > "$tmp" && mv "$tmp" "$LOG_FILE"
}

log_error() {
  local msg="$1"
  local tmp=$(mktemp)

  jq --arg err "$msg" \
     '.error = $err | .status = "failed"' "$LOG_FILE" > "$tmp" && mv "$tmp" "$LOG_FILE"
}
