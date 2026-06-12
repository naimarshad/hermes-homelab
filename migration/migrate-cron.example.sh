#!/usr/bin/env bash
# One-time migration of OpenClaw cron jobs → Hermes. Run on the Docker host
# after the Hermes stack is up. These are my real 5 jobs with the Telegram
# chat ID swapped for a placeholder — adapt the prompts, keep the structure.
#
# Source: /selfhost/openclaw/data/cron/jobs.json (all cron-expr, tz
# Europe/Berlin — container TZ is set in compose.yaml accordingly).
#
# Translation notes vs the OpenClaw originals (details in README.md):
# - "send a Telegram message via message tool" boilerplate removed: Hermes
#   auto-delivers the final response to the --deliver target and de-dupes
#   explicit send_message calls to the same destination.
# - "If no change, do nothing" → final response starts with [SILENT], which
#   suppresses delivery (output still logged in ~/.hermes/cron/output/).
# - web_fetch/web_search (OpenClaw tools) → plain instructions; Hermes's web
#   tool (SearXNG backend) handles fetch + search.
# - /home/node/... paths → /opt/data/home/... (Hermes tool-session HOME).
# - Per-job model pins dropped: jobs use the globally selected model; set
#   fallback_providers in config.yaml if needed.
set -euo pipefail

# Find yours: message the bot, then check `docker logs hermes` for the chat id
CHAT="telegram:<your-chat-id>"

echo "== Phase 1: carry over state files and scripts =="
mkdir -p /selfhost/hermes/data/home/workspace
cp -nv /selfhost/openclaw/data/workspace/*_last.txt /selfhost/hermes/data/home/workspace/ 2>/dev/null || true
cp -nv /selfhost/openclaw/scripts/update-*.sh /selfhost/hermes/scripts/ 2>/dev/null || true
chmod +x /selfhost/hermes/scripts/update-*.sh 2>/dev/null || true

echo "== Phase 2: create Hermes cron jobs =="
create() { docker exec hermes hermes cron create "$@"; }

create "0 9 * * 1,5" \
"Check the Bahn offers page for Europe summer offers.
- Fetch https://www.bahn.com/en/view/offers/index.shtml and extract the content as markdown
- Read the last known content from /opt/data/home/workspace/europe_offers_last.txt (treat a missing file as no previous content)
- Compare; if they differ, summarize the changes relevant to summer offers and overwrite the stored file with the new content
- If nothing changed, start your final response with [SILENT]" \
  --name "Check Europe summer offers" \
  --deliver "$CHAT"

create "0 0 * * 1,5" \
"Run /opt/scripts/update-claude-news.sh and ensure the daily file is saved in /opt/obsidian/news-feed/ using format YYYY-MM-DD-news-feed-claude.md." \
  --name "Daily Claude Code News Feed" \
  --deliver "$CHAT"

create "10 0 * * 1,5" \
"Run /opt/scripts/update-kubernetes-news.sh and ensure the daily file is saved in /opt/obsidian/news-feed/ using format YYYY-MM-DD-news-feed-kubernetes.md." \
  --name "Daily Kubernetes News Feed" \
  --deliver "$CHAT"

create "20 0 * * 1,5" \
"Run /opt/scripts/update-os-tech-news.sh and ensure the daily file is saved in /opt/obsidian/news-feed/ using format YYYY-MM-DD-news-feed-os-tech.md." \
  --name "Daily Open Source Tech News Feed" \
  --deliver "$CHAT"

create "30 0 * * 1,5" \
"Run /opt/scripts/update-vulnerability-news.sh and ensure the daily file is saved in /opt/obsidian/news-feed/ using format YYYY-MM-DD-news-feed-vulnerabilities.md." \
  --name "Daily Open Source Vulnerability Feed" \
  --deliver "$CHAT"

echo "== Phase 3: verify =="
docker exec hermes hermes cron list
