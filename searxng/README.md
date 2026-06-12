# SearXNG — Self-Hosted Web Search for the Hermes Agent

Privacy-respecting metasearch engine consumed by the Hermes agent's native `web` tool — no external search API, no API keys, no rate limits. LAN-only on `<your-lan-ip>:8010` (pick any free host port; container-internal port stays 8080).

## Phase 1: Prepare the Host

```bash
mkdir -p /selfhost/searxng/config
# copy settings.yml from this repo dir (enables json format, disables limiter)
cp settings.yml /selfhost/searxng/config/settings.yml
```

## Phase 2: Deploy

```bash
export SEARXNG_SECRET=$(openssl rand -hex 32)
docker compose up -d
```

(Using a Compose UI? Add `SEARXNG_SECRET` as a stack env var instead.)

Verify:

```bash
curl 'http://192.168.1.100:8010/search?q=test&format=json' | head -c 300
# JSON results = formats config is active. An HTML page or 403 means
# settings.yml wasn't picked up — check /selfhost/searxng/config/
```

## Phase 3: Wire Up Hermes

Two pieces: the URL (env) and the backend selector (config — the setup wizard
defaults it to `firecrawl` if you skipped through the search provider step):

```bash
echo "SEARXNG_URL=http://192.168.1.100:8010" >> /selfhost/hermes/data/.env
docker exec -it hermes hermes config set web.backend searxng
```

Restart the hermes stack (the supervised gateway reads config at start), then
confirm the `web` tool flipped to ✓:

```bash
docker exec -it hermes hermes doctor | grep -A2 web
```

Supported `web.backend` values: `firecrawl | searxng | brave-free | ddgs | tavily | exa | parallel | xai` — `ddgs` is a keyless fallback if SearXNG is down.

> Upgrade note (verified on v2026.6.5 / Hermes 0.16.0): SearXNG is a built-in
> backend in this version. Upstream `main` has split it into an opt-in plugin
> (`web-searxng`) — if `web` breaks after a future image bump, run
> `docker exec -it hermes hermes plugins enable web-searxng`.

## Notes

- `limiter: false` because the bot-detection limiter blocks Hermes's API-style requests and needs a valkey/redis backend. This instance is LAN-only; re-enable the limiter and add a valkey service before ever exposing it publicly.
- `search.formats` must include `json` — upstream defaults to html only, and Hermes queries `/search?format=json`.
- Image is a rolling release; bump the pinned dated tag deliberately, same policy as the hermes stack.
