#!/usr/bin/env bash
# Listens on the ntfy command topic and runs one read-only Claude Code triage per request.
# Design: homelab-docs/sre-triage-agent.md (section 6.3).
#
# Required env: NTFY_COMMAND_URL, NTFY_REPLY_URL, CLAUDE_CODE_OAUTH_TOKEN
# Optional env: TRIAGE_MODEL (sonnet), TRIAGE_DAILY_LIMIT (20), TRIAGE_COOLDOWN_SECONDS (300),
#               TRIAGE_TIMEOUT_SECONDS (600), REPO_URL, REPO_BRANCH (master)
set -uo pipefail

: "${NTFY_COMMAND_URL:?NTFY_COMMAND_URL is not set}"
: "${NTFY_REPLY_URL:?NTFY_REPLY_URL is not set}"
: "${CLAUDE_CODE_OAUTH_TOKEN:?CLAUDE_CODE_OAUTH_TOKEN is not set}"
TRIAGE_MODEL="${TRIAGE_MODEL:-sonnet}"
TRIAGE_DAILY_LIMIT="${TRIAGE_DAILY_LIMIT:-20}"
TRIAGE_COOLDOWN_SECONDS="${TRIAGE_COOLDOWN_SECONDS:-300}"
TRIAGE_TIMEOUT_SECONDS="${TRIAGE_TIMEOUT_SECONDS:-600}"
REPO_URL="${REPO_URL:-https://github.com/marmila/picluster}"
REPO_BRANCH="${REPO_BRANCH:-master}"

OPT="${OPT_DIR:-/opt/sre-triage}"
REPO="${WORK_DIR:-/work}/picluster"
STATE="${HOME}/state"           # emptyDir: lost on restart, which also resets the daily count
ALIVE="${STATE}/alive"          # touched on every ntfy event (incl. keepalives): liveness probe
REPORT_MAX_BYTES=3800           # ntfy message limit is 4096 bytes
mkdir -p "$STATE"

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }

# Post to the alerts topic. $1 title, $2 body, $3 priority (default 3), $4 tags (default robot)
reply() {
  curl -fsS -o /dev/null --max-time 20 -X POST "$NTFY_REPLY_URL" \
    -H "Title: $1" -H "Markdown: yes" -H "Priority: ${3:-3}" -H "Tags: ${4:-robot}" \
    --data-binary "$2" || log "WARN could not post reply: $1"
}

# Shallow clone kept current with fetch + reset; skills copied where Claude Code looks for them.
sync_repo() {
  if [[ ! -d "$REPO/.git" ]]; then
    git clone --quiet --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$REPO" || return 1
  else
    git -C "$REPO" fetch --quiet --depth 1 origin "$REPO_BRANCH" \
      && git -C "$REPO" reset --quiet --hard FETCH_HEAD || return 1
  fi
  rm -rf "$REPO/.claude/skills" && mkdir -p "$REPO/.claude" \
    && cp -r "$REPO/.opencode/skills" "$REPO/.claude/skills"
}

running() { [[ -f "$STATE/pid" ]] && kill -0 "$(cat "$STATE/pid")" 2>/dev/null; }

# Prints a reason and returns 1 when a new triage must not start.
gate() {
  local today count last now
  if running; then echo "a triage is already running"; return 1; fi
  today=$(date -u +%F); now=$(date +%s)
  count=0; [[ "$(cat "$STATE/day" 2>/dev/null)" == "$today" ]] && count=$(cat "$STATE/count" 2>/dev/null || echo 0)
  last=$(cat "$STATE/last" 2>/dev/null || echo 0)
  if (( now - last < TRIAGE_COOLDOWN_SECONDS )); then
    echo "cooldown, try again in $(( TRIAGE_COOLDOWN_SECONDS - (now - last) ))s"; return 1
  fi
  if (( count >= TRIAGE_DAILY_LIMIT )); then echo "daily limit of ${TRIAGE_DAILY_LIMIT} reached"; return 1; fi
  echo "$today" > "$STATE/day"; echo $(( count + 1 )) > "$STATE/count"; echo "$now" > "$STATE/last"
}

# Runs in the background: one triage, report to ntfy, full output to the pod log.
triage() {
  local request="$1" prompt out rc result is_error denials
  if [[ "${request,,}" == "triage" ]]; then
    prompt="Triage all firing alerts."
  else
    prompt="Triage all firing alerts, focusing on this request from the operator: ${request:0:500}"
  fi
  if ! sync_repo; then
    reply "Triage failed: git" "Could not clone or update ${REPO_URL}. See the pod log." 4 warning
    return
  fi
  reply "Triage started" "Model ${TRIAGE_MODEL}, timeout ${TRIAGE_TIMEOUT_SECONDS}s."
  log "triage start: ${prompt}"

  out="$STATE/out.json"
  (cd "$REPO" && timeout "$TRIAGE_TIMEOUT_SECONDS" claude -p "$prompt" \
      --agents "$OPT/agents.json" --agent sre-triage \
      --settings "$OPT/settings.json" --setting-sources project \
      --permission-mode dontAsk \
      --model "$TRIAGE_MODEL" \
      --output-format json \
      --no-session-persistence < /dev/null > "$out" 2> "$STATE/err.log")
  rc=$?

  result=$(jq -r '.result // empty' "$out" 2>/dev/null)
  is_error=$(jq -r '.is_error // false' "$out" 2>/dev/null)
  denials=$(jq -c '[.permission_denials[]?.tool_input.command // empty]' "$out" 2>/dev/null)
  log "triage end: rc=${rc} is_error=${is_error} turns=$(jq -r '.num_turns // "?"' "$out" 2>/dev/null) cost_usd=$(jq -r '.total_cost_usd // "?"' "$out" 2>/dev/null) denied=${denials:-[]}"
  log "stderr: $(tail -c 2000 "$STATE/err.log" | tr '\n' ' ')"
  printf '%s\n' "----- REPORT -----" "${result:-<empty>}" "----- END -----" >&2

  if (( rc == 124 )); then
    reply "Triage failed: timeout" "No answer within ${TRIAGE_TIMEOUT_SECONDS}s. Partial output, if any, is in the pod log." 4 warning
  elif grep -qiE 'authenticat|unauthori[sz]ed|401|oauth|/login|invalid.*(token|api key)' "$STATE/err.log" "$out" 2>/dev/null && [[ $rc -ne 0 || "$is_error" == "true" ]]; then
    reply "Triage failed: authentication" "Claude Code rejected the token: renew it (sre-triage-agent.md, 9.2)." 4 warning
  elif (( rc != 0 )) || [[ "$is_error" == "true" || -z "$result" ]]; then
    reply "Triage failed: exit ${rc}" "$(printf '%s\n\n%s' "${result:0:1500}" "$(tail -c 1000 "$STATE/err.log")")" 4 warning
  else
    if (( ${#result} > REPORT_MAX_BYTES )); then
      result="$(printf '%s' "$result" | head -c "$REPORT_MAX_BYTES" | iconv -f utf-8 -t utf-8 -c)

…cut. Full report: \`kubectl -n sre-triage logs deploy/sre-triage\`"
    fi
    reply "Triage report" "$result"
  fi
}

handle() {
  local request="$1" why
  request="$(printf '%s' "$request" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [[ -z "$request" ]] && return
  log "request: ${request:0:200}"
  if ! why=$(gate); then
    log "refused: $why"
    reply "Triage not started" "Reason: ${why}."
    return
  fi
  triage "$request" < /dev/null &   # not on the stream's stdin
  echo $! > "$STATE/pid"
}

log "starting: model=${TRIAGE_MODEL} limit=${TRIAGE_DAILY_LIMIT}/day cooldown=${TRIAGE_COOLDOWN_SECONDS}s timeout=${TRIAGE_TIMEOUT_SECONDS}s"
log "claude $(claude --version 2>/dev/null), $(kubectl version --client 2>/dev/null | head -1), flux $(flux --version 2>/dev/null)"
sync_repo && log "repo ready: $(git -C "$REPO" log -1 --format='%h %s')" || log "WARN initial clone failed, retrying at first triage"

backoff=5
while true; do
  log "subscribed to the command topic"
  touch "$ALIVE"
  # Plain stream: starts from "now". Never since=all, or a restart replays old taps (ntfy keeps 12 h).
  while IFS= read -r line; do
    touch "$ALIVE"
    backoff=5
    [[ "$(jq -r '.event // empty' <<<"$line" 2>/dev/null)" == "message" ]] || continue
    handle "$(jq -r '.message // empty' <<<"$line")"
  done < <(curl -sSN --connect-timeout 15 "${NTFY_COMMAND_URL}/json" 2> >(while IFS= read -r e; do log "curl: $e"; done))
  log "stream closed, reconnecting in ${backoff}s"
  sleep "$backoff"
  backoff=$(( backoff < 60 ? backoff * 2 : 60 ))
done
