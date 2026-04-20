#!/usr/bin/env bash
# PR Monitor — wait for CI + CodeRabbit, fix issues, repeat until clean

MAX_PR_ROUNDS="${MAX_PR_ROUNDS:-5}"
PR_POLL_INTERVAL="${PR_POLL_INTERVAL:-30}"
CR_SETTLE_TIME="${CR_SETTLE_TIME:-60}"

# Wait for all CI checks to finish. Returns 0 if green, 1 if failures.
wait_for_ci() {
  local repo="$1" pr_num="$2"
  echo "    Waiting for CI checks..."

  # Poll until checks are no longer pending
  local max_wait=600  # 10 min max
  local elapsed=0

  while [ "$elapsed" -lt "$max_wait" ]; do
    local check_output
    check_output=$(gh pr checks "$pr_num" --repo "$repo" 2>/dev/null || echo "POLL_ERROR")

    if echo "$check_output" | grep -q "POLL_ERROR"; then
      sleep "$PR_POLL_INTERVAL"
      elapsed=$((elapsed + PR_POLL_INTERVAL))
      continue
    fi

    # Check if any are still pending/queued
    if echo "$check_output" | grep -qiE "pending|queued|in_progress"; then
      sleep "$PR_POLL_INTERVAL"
      elapsed=$((elapsed + PR_POLL_INTERVAL))
      continue
    fi

    # All checks resolved — check for failures
    if echo "$check_output" | grep -qi "fail"; then
      echo "$check_output" > "$3"  # write to output file
      return 1
    fi

    echo "    CI checks all green"
    return 0
  done

  echo "    CI timed out after ${max_wait}s"
  echo "TIMEOUT: CI checks did not complete within ${max_wait}s" > "$3"
  return 1
}

# Wait for CodeRabbit review to appear after a push. Returns 0 when review is present.
wait_for_coderabbit() {
  local repo="$1" pr_num="$2" push_time="$3"
  echo "    Waiting for CodeRabbit review..."

  # Give CodeRabbit time to start
  sleep "$CR_SETTLE_TIME"

  local max_wait=300  # 5 min max after settle
  local elapsed=0

  while [ "$elapsed" -lt "$max_wait" ]; do
    # Check for CodeRabbit review (it posts as a PR review, not just comments)
    local reviews
    reviews=$(gh api "repos/$repo/pulls/$pr_num/reviews" --jq '
      [.[] | select(.user.login == "coderabbitai" or .user.login == "CodeRabbit")] | length
    ' 2>/dev/null || echo "0")

    if [ "$reviews" -gt 0 ]; then
      echo "    CodeRabbit review found"
      return 0
    fi

    # Also check for review comments (CodeRabbit sometimes posts inline only)
    local comments
    comments=$(gh api "repos/$repo/pulls/$pr_num/comments" --jq '
      [.[] | select(.user.login == "coderabbitai" or .user.login == "CodeRabbit")] | length
    ' 2>/dev/null || echo "0")

    if [ "$comments" -gt 0 ]; then
      echo "    CodeRabbit comments found"
      return 0
    fi

    sleep "$PR_POLL_INTERVAL"
    elapsed=$((elapsed + PR_POLL_INTERVAL))
  done

  echo "    No CodeRabbit review after ${max_wait}s — proceeding (may not be configured)"
  return 1
}

# Get unresolved CodeRabbit comments. Returns 0 if there are unresolved items.
get_coderabbit_feedback() {
  local repo="$1" pr_num="$2" output_file="$3"

  # Get review comments from CodeRabbit
  local cr_comments
  cr_comments=$(gh api "repos/$repo/pulls/$pr_num/comments" --jq '
    [.[] | select(
      (.user.login == "coderabbitai" or .user.login == "CodeRabbit") and
      (.position != null or .line != null)
    ) | {
      id: .id,
      path: .path,
      line: (.line // .original_line // .position),
      body: .body,
      in_reply_to_id: .in_reply_to_id
    }]
  ' 2>/dev/null || echo "[]")

  # Get top-level review body (CodeRabbit summary)
  local cr_reviews
  cr_reviews=$(gh api "repos/$repo/pulls/$pr_num/reviews" --jq '
    [.[] | select(
      (.user.login == "coderabbitai" or .user.login == "CodeRabbit") and
      .state == "CHANGES_REQUESTED"
    ) | {
      state: .state,
      body: .body
    }]
  ' 2>/dev/null || echo "[]")

  # Get issue comments from CodeRabbit (it also posts summaries as issue comments)
  local cr_issue_comments
  cr_issue_comments=$(gh api "repos/$repo/issues/$pr_num/comments" --jq '
    [.[] | select(
      .user.login == "coderabbitai" or .user.login == "CodeRabbit"
    ) | {
      body: .body
    }] | last // empty
  ' 2>/dev/null || echo "")

  local has_feedback=false

  # Check if there are CHANGES_REQUESTED reviews
  local changes_requested
  changes_requested=$(echo "$cr_reviews" | jq 'length' 2>/dev/null || echo "0")

  if [ "$changes_requested" -gt 0 ]; then
    has_feedback=true
  fi

  # Check if there are inline comments
  local comment_count
  comment_count=$(echo "$cr_comments" | jq 'length' 2>/dev/null || echo "0")

  if [ "$comment_count" -gt 0 ]; then
    has_feedback=true
  fi

  if [ "$has_feedback" = true ]; then
    cat > "$output_file" <<FBEOF
# CodeRabbit Review Feedback

## Review Status
$(echo "$cr_reviews" | jq -r '.[] | "**\(.state)**: \(.body)"' 2>/dev/null || echo "No top-level review")

## Inline Comments ($comment_count)
$(echo "$cr_comments" | jq -r '.[] | "### \(.path):\(.line)\n\(.body)\n"' 2>/dev/null || echo "None")

## Summary Comment
$(echo "$cr_issue_comments" | jq -r '.body // "None"' 2>/dev/null || echo "None")
FBEOF
    return 0
  fi

  return 1
}

# Get CI failure details for the fixer
get_ci_failures() {
  local repo="$1" pr_num="$2" output_file="$3"

  local failed_checks
  failed_checks=$(gh pr checks "$pr_num" --repo "$repo" 2>/dev/null | grep -i "fail" || echo "")

  if [ -z "$failed_checks" ]; then
    return 1
  fi

  # Get the run IDs and fetch logs
  cat > "$output_file" <<CIEOF
# CI Failures

## Failed Checks
$failed_checks

## Check Details
CIEOF

  # Try to get annotations from the failed runs
  local run_ids
  run_ids=$(gh api "repos/$repo/commits/$(gh pr view "$pr_num" --repo "$repo" --json headRefOid -q '.headRefOid')/check-runs" \
    --jq '[.check_runs[] | select(.conclusion == "failure")] | .[].id' 2>/dev/null || echo "")

  for run_id in $run_ids; do
    local annotations
    annotations=$(gh api "repos/$repo/check-runs/$run_id/annotations" --jq '.[] | "\(.path):\(.start_line) \(.annotation_level): \(.message)"' 2>/dev/null || echo "")
    if [ -n "$annotations" ]; then
      echo "$annotations" >> "$output_file"
    fi
  done

  # Also get the latest failed action run logs
  local failed_run
  failed_run=$(gh run list --repo "$repo" --branch "$(gh pr view "$pr_num" --repo "$repo" --json headRefName -q '.headRefName')" \
    --status failure --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null || echo "")

  if [ -n "$failed_run" ]; then
    echo "" >> "$output_file"
    echo "## Action Run Logs (run $failed_run)" >> "$output_file"
    gh run view "$failed_run" --repo "$repo" --log-failed 2>/dev/null | tail -100 >> "$output_file" || true
  fi

  return 0
}

# Main monitor loop: wait for CI + CodeRabbit, fix, repeat
pr_monitor_loop() {
  local repo="$1" pr_num="$2" branch="$3" project_dir="$4" plan_file="$5" log_file="$6"
  local round=0

  echo ""
  echo "========== PR Monitor: #$pr_num =========="

  while [ "$round" -lt "$MAX_PR_ROUNDS" ]; do
    round=$((round + 1))
    echo ""
    echo "  --- Monitor round $round/$MAX_PR_ROUNDS ---"

    local ci_output="$(dirname "$log_file")/ci-failures-${round}.md"
    local cr_output="$(dirname "$log_file")/cr-feedback-${round}.md"
    local needs_fix=false

    # 1. Wait for CI
    if ! wait_for_ci "$repo" "$pr_num" "$ci_output"; then
      echo "    CI failures detected"
      needs_fix=true
    fi

    # 2. Wait for CodeRabbit
    wait_for_coderabbit "$repo" "$pr_num" ""

    # 3. Check for CodeRabbit feedback
    if get_coderabbit_feedback "$repo" "$pr_num" "$cr_output"; then
      echo "    CodeRabbit feedback found"
      needs_fix=true
    fi

    # 4. If everything is clean, we're done
    if [ "$needs_fix" = false ]; then
      echo "    All clear — CI green, no CodeRabbit issues"
      return 0
    fi

    # 5. Build fix prompt
    local fix_prompt="Fix the issues found in PR #$pr_num on branch $branch in $project_dir.

## Original Plan
$(cat "$plan_file")

"
    if [ -f "$ci_output" ]; then
      fix_prompt+="
## CI Failures
$(cat "$ci_output")
"
    fi

    if [ -f "$cr_output" ]; then
      fix_prompt+="
## CodeRabbit Review Comments
$(cat "$cr_output")
"
    fi

    fix_prompt+="
Address every issue. Commit and push when done."

    # 6. Run the pr-fixer agent
    echo "    Running pr-fixer agent..."
    log_agent_start "pr-fixer" "$round" "sonnet"

    local agent_log="$(dirname "$log_file")/pr-fixer-${round}-stderr.log"

    $CLAUDE_BIN -p "$fix_prompt" \
      --dangerously-skip-permissions \
      --model sonnet \
      --system-prompt-file "$AGENTS_DIR/pr-fixer.md" \
      --add-dir "$project_dir" \
      2>"$agent_log" || { log_agent_end "pr-fixer" 1; continue; }

    log_agent_end "pr-fixer" 0

    # 7. Push fixes
    git -C "$project_dir" push 2>/dev/null || true

    echo "    Fixes pushed — looping back for next check"
  done

  echo "    ⚠ Max PR rounds ($MAX_PR_ROUNDS) reached"
  return 1
}
