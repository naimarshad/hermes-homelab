# Hermes Homelab

**A self-hosted AI agent that texts you on Telegram, watches the web for you, writes its own scripts, and survives image upgrades.**

This repo is the complete, battle-tested deployment kit for [Hermes Agent](https://hub.docker.com/r/nousresearch/hermes-agent) (by Nous Research) on a plain Docker host — plus the migration kit I used to move off **OpenClaw** without losing a single cron job or memory.

It exists because I ran OpenClaw for months, switched to Hermes in June 2026, and the migration turned out to be genuinely painless once you know the five or six gotchas. So here are the gotchas, pre-solved.

---

## What you get

- 🚀 **A pinned, reproducible Compose stack** — custom image build, healthcheck, resource limits, non-root runtime
- 🔍 **Self-hosted web search** via SearXNG — no search API keys, no rate limits
- ⏰ **5 real-world cron jobs** as worked examples (an offer watcher, daily news digests) with the OpenClaw → Hermes translation rules
- 🧠 **A memory & state migration guide** — carry your agent's accumulated knowledge to the new brain
- 🩹 **A troubleshooting section written in blood** — every entry is something that actually broke

## The 5-minute tour

```
                        ┌─────────────────────────────────────────┐
   Telegram  ◄────────► │  hermes (container)                     │
                        │  ├─ gateway        :8642  /health ✓     │
   Browser   ◄────────► │  ├─ dashboard      :8643  (basic auth)  │
                        │  └─ cron scheduler ──► your jobs        │
                        │         │                               │
                        │         ▼ web tool                      │
                        │  searxng (container) :8010              │
                        └─────────────────────────────────────────┘
                          │
                          ▼ bind mounts (everything survives rebuilds)
                        /selfhost/hermes/{data,custom-skills,extra-bins,scripts,Obsidian}
```

One agent container, one optional search container, one directory on the host that holds *everything* — config, secrets, sessions, memory, skills, logs. Blow the containers away and rebuild; the agent doesn't notice.

## Quickstart

Full runbook with explanations: [`hermes/README.md`](hermes/README.md). The short version:

```bash
# 1. One host directory to rule them all
mkdir -p /selfhost/hermes/{data,custom-skills,extra-bins,scripts,Obsidian}
sudo chown -R 1000:1000 /selfhost/hermes

# 2. Interactive setup wizard — writes config.yaml + .env for you.
#    No hand-written config. This is already nicer than OpenClaw.
docker run -it --rm -e PUID=1000 -e PGID=1000 \
  -v /selfhost/hermes/data:/opt/data \
  nousresearch/hermes-agent:v2026.6.5 setup

# 3. API key for the health endpoint
echo "API_SERVER_KEY=$(openssl rand -hex 32)" >> /selfhost/hermes/data/.env
chmod 600 /selfhost/hermes/data/.env

# 4. Smoke test before composing — separates provider errors from Docker errors
docker run --rm -e PUID=1000 -e PGID=1000 \
  -v /selfhost/hermes/data:/opt/data \
  nousresearch/hermes-agent:v2026.6.5 doctor

# 5. Lift off
cd hermes && docker compose up -d --build
curl http://<your-lan-ip>:8642/health    # {"status": "ok"}
```

Then pair Telegram (`docker exec -it hermes hermes setup gateway`) and start bossing your agent around from your phone.

## Why I switched from OpenClaw

Honest comparison from running both in the same homelab:

| | OpenClaw | Hermes Agent |
|---|---|---|
| **Configuration** | Hand-written JSON config you debug yourself | Interactive wizard generates `config.yaml` + `.env` |
| **Version safety** | `latest` tag; an auto-update once broke my stack overnight | Pinned tags; upgrades happen when *you* say so |
| **Secrets** | 7 env vars threaded through Compose | One `.env` inside the data mount, `chmod 600`, never touches the repo |
| **Health visibility** | `/health` endpoint, and that's it | `/health` + `hermes doctor` (full self-diagnosis) + supervised web dashboard |
| **Custom skills** | Updates could re-seed/overwrite the skills directory | External read-only skills dir — `hermes update` can't touch your hand-written skills |
| **Skill ecosystem** | Manual | Built-in registry: `hermes skills search/install/audit/publish` |
| **Cron output noise** | "If nothing changed, do nothing" prompt gymnastics | `[SILENT]` response prefix suppresses delivery; output still logged |
| **Message delivery** | Tell the agent to call the message tool, hope it does | `--deliver` flag on the job; final response auto-delivered, duplicate sends de-duped |
| **Memory** | Markdown files in the data dir | Cross-session memory store under `data/memory/` + the same file-based options |

And the honest gotchas, so you don't repeat my evenings ([full troubleshooting](hermes/README.md#troubleshooting)):

1. **Pull from Docker Hub, not ghcr.io.** The GitHub registry only holds their CI build cache. Yes, I learned this the slow way.
2. **`API_SERVER_HOST=0.0.0.0` or no health for you.** The API server binds container-loopback by default, so the published port can't reach it. The compose file in this repo sets it.
3. **Cron has no per-job timezone.** Pin the container's `TZ` to whatever your schedules assume.
4. **The wizard may default to a free model** if you hand it an OpenRouter key. `hermes model` fixes it in ten seconds.
5. **Trust the docs at your pinned tag, not `main`.** Upstream `main` documents features your release doesn't have yet.

## Repo layout

| Path | What it is |
|---|---|
| [`hermes/`](hermes/) | The agent stack: `compose.yaml`, `Containerfile`, full phase-by-phase runbook |
| [`searxng/`](searxng/) | Optional self-hosted web search backend for the agent's `web` tool |
| [`migration/`](migration/) | OpenClaw → Hermes: cron job translation rules + script, memory & state carry-over |

## Coming from OpenClaw?

Start with [`migration/README.md`](migration/README.md). The whole move is: deploy Hermes alongside OpenClaw, copy state files and the Obsidian vault, run the cron migration script, watch both run for 48 hours, decommission OpenClaw. No flag day, no data loss.

## License

[MIT](LICENSE). If this saved you an evening, a ⭐ says thanks.
