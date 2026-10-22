# Last time on Valorant

An optional two-player match rewind for a TRMNL private plugin: three newest finished matches, compact commentary, individual K/D/A, and kills/ACS charts. Full, horizontal half, vertical half and quadrant layouts are included. Dates default to America/Chicago, including daylight saving changes. The quadrant shows only the newest match; charts appear in the full layout on larger screens.

This folder is independent of the original `TRMNL/Trmnl_ValorantTracker.ps1`, `Template.html`, and the existing GitHub Actions workflow. Installing these files does not activate a scheduler, modify a playlist, or post to Discord. Nothing reads Discord configuration or posted state.

## Requirements

- Node.js 22 or later and PowerShell 7 (`pwsh` on PATH, or set `PWSH_PATH` to its executable).
- A HenrikDev API key available through the process environment variable `HENRIK_API_KEY`. Supply it through your secret manager; do not put it in files, commands you share, logs, or Git.
- For publication, choose one: set `TRMNL_API_KEY` to a TRMNL **account API** token through your process environment, or use an installed TRMNL Control source checkout with dependencies installed and its normal OAuth login completed. For the latter, set `TRMNL_CONTROL_ROOT` to that checkout's absolute directory. The adapter uses its existing stored OAuth configuration; no token is copied here. A device token or webhook UUID is not an account API token.
- An explicitly selected private plugin setting and device. This integration publishes data and requests plugin rendering only. Add the plugin to the desired device through your normal TRMNL setup.

TRMNL Control's optional adapter uses its `src/config.mjs`, `src/server.mjs` and `ctx.client.execute` interfaces. Those interfaces should be checked when updating TRMNL Control. The direct adapter requires no npm dependencies and sends authenticated requests only to `https://trmnl.com`, with redirects disabled. Offline tests do not validate a user's live API permissions or device display.

## Configure locally

Run commands from this folder. Copy `config.example.json` to ignored `config.local.json`. Set your two display names/Riot IDs, region, timezone and exact target IDs. Zero IDs intentionally prevent publication. The example names and all demo data are fictional.

```powershell
Copy-Item config.example.json config.local.json
npm test
node demo.mjs
```

The commands below use `.state/` for private runtime files. If you use `--state` to choose a different directory, keep it outside version control. Local filesystem permissions still apply; `.gitignore` prevents accidental Git staging, not access by other local users.

## Install the layouts

Create a private webhook plugin using Framework 3.4.0. Paste `layouts/shared.liquid` into its shared markup, then the matching `full.liquid`, `half_horizontal.liquid`, `half_vertical.liquid` and `quadrant.liquid` into their layout fields. `layouts/settings.yml` documents the settings. Use `node demo.mjs` output as sample merge variables to preview. It contains no live account data. Inspect layouts on your device size before deployment; API acceptance and browser previews do not prove the physical screen refreshed.

## Fetch, write, inspect, publish

```powershell
node fetch.mjs
# Read .state/candidate.json, then write .state/input.json using the contract below.
node publish.mjs --dry-run
node publish.mjs
```

`fetch.mjs` calls only the HenrikDev history GET endpoint for the two configured players. It unions the histories, filters finished tracked-player matches, deduplicates, sorts by source UTC time, takes at most three, and builds deterministic digests. A partial fetch or digest failure preserves the previous candidate/card and marks the attempt failed. Publishing then refuses an older candidate, even if it is still within the two-hour freshness window. Increase `scanSize` up to 10 for a wider API history window; this is not an unlimited archive.

Create `.state/input.json` with exactly one entry per current candidate, newest first:

```json
{
  "matches": [
    {
      "id": "copy-current-candidate-id",
      "headline": "Up to 55 characters",
      "commentary": "Up to 230 characters, using only current digest facts.",
      "short": "Up to 130 characters for compact layouts."
    }
  ]
}
```

Use `COMMENTARY.md` as the writer's factual contract. A human or an existing assistant can write these fields. The software does not call a model or require an AI API key. Reuse commentary only when the match's digest facts are unchanged. Array order in unrelated notable events may vary; recheck relevant facts before reusing. Text validation enforces length and rejects markup, ping syntax and em dashes; it cannot prove that prose is factually accurate.

The publisher derives every score, date and chart value from the digest. Missing players remain null. Unsupported team modes and conflicting score/round/winner fields show `Stats only`/`N/A`. Synthetic surrender rounds must not be presented as rounds actually played. Clutch/highlight reconstruction depends on source kill timelines; incomplete source details require a factual stat summary.

Dry run validates the payload and 5,000-byte limit without loading OAuth or making a network request. Publication first reads remote variables, writes once, verifies readback, saves private receipts, then requests rendering. Identical content checked within the last 55 minutes skips the write. Later successful checks renew `checked_at` even with no new games. A three-hour-old check displays an update-delayed indicator.

## Failure handling

- Fetch failure: preserve the card and checked time. Wait for the next successful fetch.
- HTTP 429: respect the reported retry-after. No automatic write retries are performed.
- Timeout/uncertain write: use TRMNL Control's `getMergeVariables` for the configured plugin setting. Compare `content_hash` and `checked_at` before considering another write.
- Verified data plus render failure: the receipt records `renderPending`. Request `startRefresh` for that setting only; do not resend data merely to trigger rendering.
- A target differing from the prior receipt is rejected. Use a separate private state directory for a different plugin/device.
- Lock remains after a crashed process: verify that process is no longer running before removing that one lock. Locks are never reclaimed merely because they are old.

## Optional recurring use

No schedule is installed by this addition. If you already have an hourly assistant automation, update it to run the four-step workflow above with this folder and exact local target. Have it read fresh candidate digests and write commentary only when needed. Instruct it to stay quiet on routine success and report persistent failure or required action. Use only one scheduler for this feed. A local run requires the computer and scheduler/assistant application to be running. The original repository workflow continues to operate independently.

## Safe contribution boundary

Commit source, templates, docs and fictional fixtures only. Never commit `config.local.json`, `.env`, `.state`, raw matches, player history, OAuth files, webhook URLs, receipts, screenshots from a live card, or any API credentials. The source export includes a standalone version of the deterministic digest builder; it has no dependency on a private recap-agent installation or its configuration.
