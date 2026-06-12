# OpenClaw → Hermes Migration Kit

How I moved a live OpenClaw deployment (Telegram gateway, 7 cron jobs, months of accumulated notes and state) to Hermes Agent with zero data loss and no flag day.

**The strategy: run both side by side.** Deploy Hermes next to OpenClaw (different ports, different host directories), migrate state and jobs, watch both for 24–48 hours, then decommission OpenClaw. At no point is there a moment where neither agent works.

```
Day 0      Deploy Hermes alongside OpenClaw (see ../hermes/README.md)
Day 0      Copy state files + scripts, first Obsidian sync   ← this guide
Day 0      Run migrate-cron.example.sh (adapted to your jobs)
Day 0–2    Both agents run; compare cron outputs
Day 2      Final Obsidian rsync, stop OpenClaw, archive
```

---

## Part 1: Memory & State

An agent's "memory" is really four different things, and they migrate differently:

| What | OpenClaw location | Hermes destination | How |
|---|---|---|---|
| Workspace state files (e.g. `*_last.txt` that cron jobs diff against) | `/selfhost/openclaw/data/workspace/` | `/selfhost/hermes/data/home/workspace/` | Plain `cp` |
| Agent-written scripts | `/selfhost/openclaw/scripts/` | `/selfhost/hermes/scripts/` (→ `/opt/scripts`) | `cp` + `chmod +x` |
| Notes vault (Obsidian) | `/selfhost/openclaw/Obsidian/` | `/selfhost/hermes/Obsidian/` (→ `/opt/obsidian`) | `rsync` twice: once at setup, final pass at decommission |
| Long-term agent memory (markdown facts OpenClaw accumulated) | `/selfhost/openclaw/data/` memory files | Hermes's own store under `/selfhost/hermes/data/memory/` | See below — don't copy raw |

The first three are file copies:

```bash
# State files the cron jobs compare against (-n: never overwrite)
mkdir -p /selfhost/hermes/data/home/workspace
cp -nv /selfhost/openclaw/data/workspace/*_last.txt /selfhost/hermes/data/home/workspace/

# Agent-written scripts
cp -nv /selfhost/openclaw/scripts/*.sh /selfhost/hermes/scripts/
chmod +x /selfhost/hermes/scripts/*.sh

# Notes vault — copy while OpenClaw still runs; final rsync at decommission
rsync -a /selfhost/openclaw/Obsidian/ /selfhost/hermes/Obsidian/
```

**Watch the path translation.** OpenClaw's tool sessions ran under `/home/node/`; Hermes's home is `/opt/data` and tool subprocesses get `HOME=/opt/data/home`. Any migrated script or cron prompt that hardcodes `/home/node/...` must become `/opt/data/home/...` — this is the single most common migration bug.

### Long-term memory: let the agent re-ingest it

Don't copy OpenClaw's memory files into Hermes's `data/memory/` — the formats aren't compatible and Hermes manages that directory itself. Instead, stage the old files where Hermes can read them and let it do the import with its own memory tool:

```bash
mkdir -p /selfhost/hermes/data/home/openclaw-import
cp -rv /selfhost/openclaw/data/memory* /selfhost/hermes/data/home/openclaw-import/ 2>/dev/null || true
```

Then, in a chat with Hermes (Telegram or `docker exec -it hermes hermes chat`):

> Read the files under ~/openclaw-import/. They are the long-term memory of your predecessor. Store the facts that are still relevant in your own memory — preferences, recurring tasks, infrastructure details, things I've corrected before. Skip anything stale.

This beats a raw copy: the agent deduplicates, drops stale facts, and stores everything in its native format. Spot-check afterwards ("what do you remember about my infrastructure?") and delete the import directory when satisfied.

---

## Part 2: Cron Jobs

OpenClaw kept jobs in `data/cron/jobs.json`; Hermes creates them via `hermes cron create`. [`migrate-cron.example.sh`](migrate-cron.example.sh) is my actual migration script (7 jobs: rail-offer watchers and daily news digests) with the chat ID swapped for a placeholder — adapt the prompts, keep the structure.

### Translation rules (the important part)

These are the systematic rewrites between an OpenClaw cron prompt and a Hermes one:

1. **Delete the delivery boilerplate.** OpenClaw prompts ended with "send a Telegram message via the message tool". Hermes auto-delivers the final response to the job's `--deliver` target and de-dupes explicit `send_message` calls to the same destination — the instruction is now harmful noise.
2. **"If nothing changed, do nothing" → `[SILENT]`.** Hermes suppresses delivery when the final response starts with `[SILENT]` (output is still logged in `~/.hermes/cron/output/`). This turns prompt gymnastics into a one-word convention — my favorite single feature of the switch.
3. **Tool names → plain instructions.** OpenClaw prompts called out `web_fetch`/`web_search` by name. Hermes's `web` tool handles fetch and search behind plain English — just say what to fetch and compare.
4. **Translate HOME paths.** `/home/node/...` → `/opt/data/home/...` (see Part 1).
5. **Drop per-job model pins.** OpenClaw jobs each pinned a model with a free-model fallback. Hermes jobs use the globally selected model; configure `fallback_providers` in `config.yaml` if you need a fallback.
6. **Pin the container timezone.** Hermes cron has no per-job timezone, so set `TZ` in the compose environment to whatever your schedules assume (this stack pins `Europe/Berlin`). Forget this and your 08:00 job runs at 06:00 UTC.

### Verify

```bash
docker exec hermes hermes cron list                       # all jobs present, schedules right
docker exec -it hermes ls /opt/data/home/workspace/        # state files in place
# After first scheduled runs: compare outputs against OpenClaw's for a day or two
```

---

## Part 3: Decommission OpenClaw

Only after 24–48 hours of stable Hermes operation:

```bash
# Final notes-vault sync (Hermes uses its own copy)
rsync -a /selfhost/openclaw/Obsidian/ /selfhost/hermes/Obsidian/

# Stop the OpenClaw stack, then archive — don't delete, archive
tar -czf /selfhost/openclaw-final-backup-$(date +%Y%m%d).tar.gz /selfhost/openclaw/
```

Re-point your reverse proxy / Cloudflare Tunnel from OpenClaw's port to Hermes's `8642`, and you're done. Note that `8642` is a pure API server — `/` returns 404 by design; `/health` is the liveness route.
