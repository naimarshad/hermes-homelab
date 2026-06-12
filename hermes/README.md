# Hermes Agent — Deployment Runbook

> Wizard-generated config + host bind mounts + a Compose stack with healthcheck.
> Isolated from the host, provider-agnostic auth, Telegram gateway.

The stack is this directory: `compose.yaml` (the only file Compose needs), `Containerfile` (custom image), and this runbook. **Secrets never enter the repo** — they live in `/selfhost/hermes/data/.env` on the host.

Throughout: `192.168.1.100` is a placeholder for your Docker host's LAN IP, and UID/GID `1000` for your host user. Adjust both.

---

## Design Decisions (Why This Setup)

| Choice | Reasoning |
|--------|-----------|
| Wizard writes config | No hand-written config to debug — the wizard produces a valid `config.yaml` + `.env` in the mounted volume |
| One root `/selfhost/hermes/` | Everything (data, custom skills, extra binaries, scripts, notes) persists under one host directory — trivial to back up, trivial to reason about |
| External skills mount | Hand-authored skills in `/selfhost/hermes/custom-skills` are only *read* by Hermes — `hermes update` never re-seeds or overwrites them |
| Writable bin mount | Binaries dropped into `/selfhost/hermes/extra-bins` on the host are instantly callable (PATH-prepended) — no image rebuild |
| `API_SERVER_ENABLED=true` + `API_SERVER_HOST=0.0.0.0` | Required for `/health` to respond — without ENABLED, 8642 isn't listening; without HOST, it binds container-loopback and the published port can't reach it. Both set in compose; only `API_SERVER_KEY` goes in `.env` |
| Bind to a LAN IP | A reverse proxy / Cloudflare Tunnel reaches the gateway directly; never exposed beyond the LAN without auth in front |
| `PUID/PGID=1000` | Root exists only during s6 init (UID remap + volume chown); gateway, dashboard, and all tool processes drop to the `hermes` user remapped to your host UID, and upstream refuses a root gateway by default. Bind-mounted files stay host-editable |
| Pinned image tag | `latest` auto-updates have broken stacks overnight. Pin, and upgrade deliberately |
| docker.sock mount (optional) | Lets the agent manage containers via UID + docker group membership — it never touches the host root filesystem or processes. Remove it if you don't want this |

---

## Phase 1: Prepare the Host Directories

```bash
mkdir -p /selfhost/hermes/{data,custom-skills,extra-bins,scripts,Obsidian}

# Confirm ownership matches your host user (UID/GID 1000 here)
stat -c '%u:%g %n' /selfhost/hermes /selfhost/hermes/*
# If not 1000:1000:
sudo chown -R 1000:1000 /selfhost/hermes
```

> Pre-creating the directories matters: Docker creates missing bind-mount sources as `root:root`, and the credentials subdirectory must be writable before first Telegram pairing or messages get silently dropped. The setup wizard creates it — run the wizard before starting the gateway; don't skip Phase 2.

---

## Phase 2: Run the One-Time Setup Wizard

This replaces hand-writing a config file. It runs interactively, prompts for provider keys, and writes `config.yaml` + `.env` into the mounted volume.

```bash
docker run -it --rm \
  -e PUID=1000 -e PGID=1000 \
  -v /selfhost/hermes/data:/opt/data \
  nousresearch/hermes-agent:v2026.6.5 setup
```

During the wizard:

1. **Setup mode** — pick **Full setup** (bring your own keys) to use OpenAI/OpenRouter; Quick Setup routes everything through Nous Portal instead.
2. **API keys** — enter what it asks for; the wizard writes them to `/selfhost/hermes/data/.env`.
3. **Terminal backend** — keep `local` (commands already run inside this container).
4. **Skip gateway setup for now** if asked — Telegram is configured after the model is confirmed working.
5. **Default model gotcha** — with an OpenRouter key the wizard may default to a free model (e.g. `nvidia/nemotron-…:free`). Pick your real model afterwards: `hermes setup model` (or `hermes model`).

Verify the files exist on the host:

```bash
ls -la /selfhost/hermes/data/
# Expect: config.yaml, .env, and supporting directories
```

---

## Phase 3: Enable the API Server + Register External Skills

### API server (for healthcheck)

The `/health` endpoint only responds when the API server is on. `compose.yaml` already sets `API_SERVER_ENABLED=true` and `API_SERVER_HOST=0.0.0.0` (the latter is required — the server defaults to container-loopback, which the published port can't reach). You only add the key (minimum 8 characters) to the wizard-generated `.env`:

```bash
echo "API_SERVER_KEY=$(openssl rand -hex 32)" >> /selfhost/hermes/data/.env
chmod 600 /selfhost/hermes/data/.env
```

### External skills directory

Register the custom-skills mount in `/selfhost/hermes/data/config.yaml`:

```yaml
skills:
  external_dirs:
    - /opt/custom-skills
```

Each hand-authored skill is a folder with `SKILL.md` at the leaf:

```
/selfhost/hermes/custom-skills/
├── my-workspace/
│   ├── SKILL.md
│   └── scripts/
└── k8s-ops/
    ├── SKILL.md
    └── references/
```

Everything else skill-related already persists with zero config: bundled skills, agent-auto-generated skills (the `skill_manage` learning loop), skill bundles, and registry installs all land under `~/.hermes/skills/` inside `/opt/data` → `/selfhost/hermes/data/skills/` on the host.

| Directory | Holds | Survives `hermes update`? |
|-----------|-------|--------------------------|
| `/selfhost/hermes/data/skills/` | Bundled + agent-auto-generated | Bundled get re-seeded/updated; auto-gen untouched |
| `/selfhost/hermes/custom-skills/` | Hand-authored skills (git-versionable) | Yes, fully — Hermes only reads it |

---

## Phase 4: Smoke Test Before Composing

Confirm model and auth work in isolation — separates provider errors from container/Compose errors.

```bash
docker run --rm \
  -e PUID=1000 -e PGID=1000 \
  -v /selfhost/hermes/data:/opt/data \
  nousresearch/hermes-agent:v2026.6.5 doctor
```

One-shot chat test:

```bash
docker run --rm -it \
  -e PUID=1000 -e PGID=1000 \
  -v /selfhost/hermes/data:/opt/data \
  nousresearch/hermes-agent:v2026.6.5 chat -q "say hello"
```

If it errors on auth, re-run the setup wizard's login step. Do not proceed until this works.

Expected non-blockers in `doctor` output (verified 2026-06-12 on v2026.6.5):

- `~/.local/bin/hermes not found` — fix once with `hermes doctor --fix`; the symlink lands in `/opt/data/.local/bin` (inside the data mount, already on the image PATH) so it persists
- `agent-browser npm vulnerabilities` — the Containerfile runs a best-effort `npm audit fix` at build; residual advisories wait for the next upstream tag
- `OpenAI Codex auth (not logged in)` — `image_gen`/`vision` stay down until `docker exec -it hermes hermes auth` (Codex OAuth, persists in data mount)
- `web` tool missing keys — the free DuckDuckGo search skill still works; for the native tool deploy [`../searxng/`](../searxng/) and set `SEARXNG_URL` in `data/.env`
- `No GITHUB_TOKEN` — only throttles Skills Hub; add to `data/.env` if needed

What must be green: your provider under API Connectivity, and the core tools (terminal, file, memory, skills, browser, code_execution).

---

## Adding or Changing Providers Later (no full wizard re-run)

The full wizard is first-time-only. Providers are just entries in `/opt/data/.env` plus the model picker — keys are additive (adding OpenAI doesn't remove OpenRouter); the *active* model is whatever the picker selects.

```bash
# Add a provider by API key — same file the wizard writes
echo "OPENAI_API_KEY=sk-..." >> /selfhost/hermes/data/.env

# Or run only the model/provider section of the wizard
docker run -it --rm -e PUID=1000 -e PGID=1000 \
  -v /selfhost/hermes/data:/opt/data \
  nousresearch/hermes-agent:v2026.6.5 setup model

# OpenAI via ChatGPT subscription (Codex OAuth) — tokens persist in the data
# mount and also unlock image_gen/vision (wizard points them at openai-codex)
docker run -it --rm -e PUID=1000 -e PGID=1000 \
  -v /selfhost/hermes/data:/opt/data \
  nousresearch/hermes-agent:v2026.6.5 auth

# Switch the active model/provider (also fixes the free-model default)
docker run -it --rm -e PUID=1000 -e PGID=1000 \
  -v /selfhost/hermes/data:/opt/data \
  nousresearch/hermes-agent:v2026.6.5 model
```

Once the stack is running, skip the `docker run` wrapper and exec instead:

```bash
docker exec -it hermes hermes model           # switch active model/provider
docker exec -it hermes hermes auth            # OAuth logins (Codex, Portal, ...)
docker exec -it hermes hermes setup model     # provider section of the wizard
docker exec -it hermes hermes setup tools     # tool providers (search, TTS, ...)
docker exec -it hermes hermes setup gateway   # messaging platforms
```

Restart the stack after `.env` changes — exec-based changes apply live.

---

## Skills Hub (community skill registry)

One-time init + better rate limits:

```bash
docker exec -it hermes hermes skills list                    # initializes the hub directory
echo "GITHUB_TOKEN=ghp_..." >> /selfhost/hermes/data/.env    # lifts 60 req/hr anon limit (no scopes needed)
# restart stack after the .env change
```

Day-to-day (all also work as `/skills <subcommand>` from chat, e.g. Telegram):

```bash
docker exec -it hermes hermes skills search <query>     # search registries
docker exec -it hermes hermes skills browse             # paginated catalog
docker exec -it hermes hermes skills inspect <name>     # README/metadata before installing
docker exec -it hermes hermes skills install <name>     # installs into data/skills/ (persists)
docker exec -it hermes hermes skills list               # what's installed, by source
docker exec -it hermes hermes skills check              # verify installed skills are intact
docker exec -it hermes hermes skills update [<name>]    # update one or all
docker exec -it hermes hermes skills audit [<name>]     # security review of skill contents
docker exec -it hermes hermes skills uninstall <name>
```

Community give-back: `hermes skills publish <path>` shares a skill from `custom-skills/` to GitHub; `hermes skills tap add <owner/repo>` subscribes to a third-party registry. Installed skills land in `data/skills/` (host-visible, survives rebuilds); your own authored ones stay in `custom-skills/`.

---

## Phase 5: Deploy the Stack

```bash
cd hermes/
docker compose up -d --build
```

Key points (see inline comments in `compose.yaml`):

- **Image** — built locally as `hermes-custom:local` from the `Containerfile`: pinned upstream base (`nousresearch/hermes-agent:v2026.x.y` on **Docker Hub — NOT ghcr.io**, that only holds their CI build cache; never `latest`) plus apt deps the stock image lacks (`jq`, `tmux`, `unzip`). Bump the version in the Containerfile `FROM` line.
- **Secrets** — not in the Compose file or this repo. The container reads `/selfhost/hermes/data/.env` from inside the `/opt/data` mount.
- **Healthcheck** — hits `/health`; works because of `API_SERVER_ENABLED=true` (Phase 3). If a future image drops `curl`, switch the test to `wget -qO- http://127.0.0.1:8642/health`.
- **`start_period: 40s`** — gives the s6 supervisor time to bring the gateway up before failures count.

Using a Compose UI (Portainer, Dockhand, Komodo...)? Point it at this Git repo with compose path `hermes/compose.yaml` — no stack-level env vars or secrets needed, and you get auto-redeploy on push for free.

Verify from the host:

```bash
curl http://192.168.1.100:8642/health   # {"status": "ok"} — gateway binds the LAN IP, not localhost
docker ps --filter name=hermes          # status shows (healthy), ~40–70s after start
```

---

## Phase 6: Configure the Telegram Gateway

```bash
docker exec -it hermes hermes setup gateway
```

Follow the prompts to add the Telegram bot token and pair your account. Session data writes to `/selfhost/hermes/data/sessions/` and persists.

Verify:

```bash
docker exec -it hermes hermes gateway status
docker logs hermes --tail 50          # look for "[gateway] Connected" + inbound message line
```

---

## Phase 7: Expose Beyond the LAN (optional)

Point a Cloudflare Tunnel (or any reverse proxy) at the gateway:

```
ai.example.com  →  http://192.168.1.100:8642
```

Note: port 8642 is a pure API server — `/` returns 404 **by design**; `/health`, `/v1/*`, `/api/*` are the real routes. The browser UI is the dashboard below.

### Web Dashboard (port 8643)

The compose file enables the supervised dashboard (`HERMES_DASHBOARD=1`, container port 9119 → host 8643). It exposes API keys and session data, so the basic-auth gate is **mandatory** before tunneling it. Add to `/selfhost/hermes/data/.env` and restart the stack:

```bash
cat >> /selfhost/hermes/data/.env <<EOF
HERMES_DASHBOARD_BASIC_AUTH_USERNAME=<your-username>
HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=<strong-password>
HERMES_DASHBOARD_BASIC_AUTH_SECRET=$(openssl rand -hex 32)
EOF
```

The auth plugin activates automatically once username+password are set (no `plugins enable` needed); `_SECRET` keeps sessions valid across restarts. Verify the gate before exposing: `http://192.168.1.100:8643` must redirect to a login page. Upstream marks basic auth as not suitable for direct public exposure — put Cloudflare Access (or similar) in front of the tunnel hostname, or switch to OIDC against your IdP (`HERMES_DASHBOARD_OIDC_ISSUER` + `_CLIENT_ID`).

---

## Phase 8: Tool Binaries

Skills (SKILL.md folders) persist via the mounts above; **tool binaries** the skills call are separate, because the sandbox is read-only at runtime. Two options:

**A — writable bin mount (default in compose.yaml, no rebuild):** drop static binaries (kubectl, jq, yq, gh, rclone...) into `/selfhost/hermes/extra-bins/` on the host — `/opt/bin` is prepended to PATH, so they're instantly callable.

**B — bake into the image (versioned with the image):** the stack already builds `hermes-custom:local`; put binaries in `extra-bins/` next to the `Containerfile` and uncomment its `COPY` line. Use this for anything with shared-library deps that apt doesn't package (apt deps just go in the Containerfile's package list, like `jq`/`tmux`/`unzip` already do).

---

## Troubleshooting

Every entry here is something that actually happened.

### Healthcheck never passes / container marked unhealthy

API server isn't enabled or can't be reached:
```bash
# Compose must set API_SERVER_ENABLED=true and API_SERVER_HOST=0.0.0.0
docker exec hermes env | grep API_SERVER
# .env must contain a key of at least 8 chars
grep API_SERVER_KEY /selfhost/hermes/data/.env
```
Restart the stack after fixing.

### `curl: Connection reset by peer` on /health

Same root cause — API server disabled, or the gateway is still starting. Wait past `start_period`, then re-check. Confirm the gateway logged `API server listening on http://127.0.0.1:8642`.

### Telegram messages silently dropped

Credentials/sessions directory wasn't writable at pairing time:
```bash
stat -c '%u:%g' /selfhost/hermes/data/sessions
sudo chown -R 1000:1000 /selfhost/hermes
```

### Bind-mounted dirs owned by root on the host

Docker creates missing bind-mount source dirs as `root:root`, and a container that dies before stage2's ownership fix (e.g. a bad image) never corrects them. Pre-create all dirs in Phase 1; to repair:

```bash
sudo chown -R 1000:1000 /selfhost/hermes
```

Also confirm `PUID`/`PGID` in the Compose environment match the host directory owner — supervised processes run as that UID instead of the default 10000.

### Gateway shows nothing in `docker logs`

The s6 supervisor has multiple log surfaces:
```bash
docker exec -it hermes ls /opt/data/logs/
docker exec -it hermes tail -f /opt/data/logs/gateway.log
```

### Data directory on NFS? Don't nest mounts under it

If `/selfhost/hermes/data` lives on an NFS export, do **not** add bind mounts nested inside it (e.g. mounting something at `/opt/data/home/.config`). Nested binds over an NFS-backed parent delivered writes to the underlay non-deterministically — cron jobs wrote to one copy while `docker exec` saw another (verified by inode comparison). Keep every mount a sibling under `/opt/`, and use host-side symlinks if you need layout continuity.

---

## Quick Reference

| Task | Command |
|------|---------|
| Health check | `curl http://192.168.1.100:8642/health` |
| Container status | `docker ps --filter name=hermes` |
| Gateway status | `docker exec -it hermes hermes gateway status` |
| Doctor | `docker exec -it hermes hermes doctor` |
| Follow logs | `docker logs hermes -f` |
| Gateway logs (s6) | `docker exec -it hermes tail -f /opt/data/logs/gateway.log` |
| Re-run setup | `docker run -it --rm -v /selfhost/hermes/data:/opt/data nousresearch/hermes-agent:TAG setup` |
| Edit secrets | `nano /selfhost/hermes/data/.env` then restart stack |

---

## File Layout Summary

```
/selfhost/hermes/                 ← one root per app on the host
├── data/                         ← Hermes home (→ /opt/data)
│   ├── config.yaml               ← wizard-generated agent config (+ skills.external_dirs)
│   ├── .env                      ← secrets + API_SERVER_KEY (chmod 600)
│   ├── sessions/                 ← Telegram pairing / session state
│   ├── memory/                   ← cross-session memory store
│   ├── skills/                   ← bundled + agent-auto-generated skills
│   └── logs/                     ← s6 supervised process logs
├── custom-skills/                ← hand-authored skills (→ /opt/custom-skills, read-only to Hermes)
├── extra-bins/                   ← drop-in tool binaries (→ /opt/bin, PATH-prepended)
├── scripts/                      ← agent-written shell/python scripts (→ /opt/scripts)
└── Obsidian/                     ← notes vault (→ /opt/obsidian), optional

hermes/ (this repo)               ← the Compose stack
├── compose.yaml                  ← the only file Compose needs
├── Containerfile                 ← pinned base + extra apt deps
└── README.md                     ← this runbook
```
