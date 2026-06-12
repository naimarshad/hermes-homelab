#!/usr/bin/env bash
# One-time migration of OpenClaw cron jobs → Hermes. Run on the Docker host
# after the Hermes stack is up. These are my real 7 jobs with the Telegram
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

create "0 8 * * 1,5" \
"Check the Bahn familienticket page for changes AND check for family holiday ticket mentions across Europe.

Bahn familienticket:
- Fetch https://www.bahn.de/service/individuelle-reise/kinder/familienticket and extract the content as markdown
- Read the last known content from /opt/data/home/workspace/familienticket_last.txt
- Compare; if they differ, summarize what changed and update the stored file

European family holiday ticket news:
- Search the web for recent mentions with queries: \"family holiday ticket\" Europe, \"family train ticket\" Europe, \"kinder ticket\" Europe, \"familienticket\" Europe, \"family vacation ticket\" Europe
- Read the last known summary from /opt/data/home/workspace/euro_family_ticket_news_last.txt
- If there are new relevant mentions, summarize them and update the stored file

If web search fails, note the issue but still do the Bahn check.
If neither source changed, start your final response with [SILENT]." \
  --name "Check Bahn familienticket and European family holiday ticket news" \
  --deliver "$CHAT"

create "0 9 * * 1,5" \
"Check the Bahn offers page for Europe summer offers.
- Fetch https://www.bahn.com/en/view/offers/index.shtml and extract the content as markdown
- Read the last known content from /opt/data/home/workspace/europe_offers_last.txt (treat a missing file as no previous content)
- Compare; if they differ, summarize the changes relevant to summer offers and overwrite the stored file with the new content
- If nothing changed, start your final response with [SILENT]" \
  --name "Check Europe summer offers" \
  --deliver "$CHAT"

create "0 10 * * 1,5" \
"Check family train offers across European rail operators AND search for family holiday ticket news.

Part 1 — operator pages (handle each independently; skip failures and continue):
1. Deutsche Bahn: https://www.bahn.de/service/individuelle-reise/kinder/familienticket
2. SNCF: https://www.sncf.com/en/train-ticket/reduction/family
3. OEBB: https://www.oebb.at/en/ticket-offers/
4. NS International: https://www.nsinternational.com/en
For each: fetch and extract as markdown, compare against /opt/data/home/workspace/{operator}_family_last.txt, and if different summarize the change and update the stored file.

Part 2 — news: search the web for \"family holiday ticket\" / \"family train ticket\" / \"kinder ticket\" Europe (recent results), compare against /opt/data/home/workspace/euro_family_ticket_news_last.txt, summarize anything new and update the stored file.

If every fetch failed, report the failure. If nothing changed anywhere, start your final response with [SILENT]." \
  --name "Check European family train offers and holiday ticket news" \
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
