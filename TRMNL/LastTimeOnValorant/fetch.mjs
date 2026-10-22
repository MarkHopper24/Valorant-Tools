import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { randomUUID } from 'node:crypto';
import { atomicJson, hash, readJson, selectFinished, withLock } from './core.mjs';
import { options } from './options.mjs';

const exec = promisify(execFile);
export async function fetchHistory(config, apiKey, fetcher = fetch) {
  if (!apiKey) throw new Error('Set HENRIK_API_KEY in the process environment.');
  const histories = [];
  for (const p of config.players) {
    const [name, tag] = p.riot.split('#');
    const url = `https://api.henrikdev.xyz/valorant/v3/matches/${config.region}/${encodeURIComponent(name)}/${encodeURIComponent(tag)}?size=${config.scanSize}`;
    let response;
    try { response = await fetcher(url, { headers: { Authorization: apiKey }, redirect: 'error', signal: AbortSignal.timeout(60000) }); }
    catch { throw new Error('History request failed; previous card preserved.'); }
    if (!response.ok) {
      const retry = response.status === 429 ? response.headers.get('retry-after') : null;
      throw new Error(`History HTTP ${response.status}; previous card preserved.${retry && /^\d+$/.test(retry) ? ` Retry after ${retry} seconds.` : ''}`);
    }
    let body;
    try { const raw = await response.text(); if (raw.length > 16 * 1024 * 1024) throw new Error(); body = JSON.parse(raw); }
    catch { throw new Error('Invalid history response; previous card preserved.'); }
    if (body.status !== 200 || !Array.isArray(body.data)) throw new Error('Incomplete history; previous card preserved.');
    histories.push(body.data);
  }
  return histories;
}
async function main() {
  const { config, state } = await options();
  await withLock(path.join(state, 'fetch.lock'), async () => {
    const runId = randomUUID(), statusPath = path.join(state, 'fetch-status.json');
    await atomicJson(statusPath, { status: 'running', runId });
    try {
      const rows = selectFinished(await fetchHistory(config, process.env.HENRIK_API_KEY), config);
      const staging = path.join(state, 'runs', runId);
      await fs.mkdir(staging, { recursive: true });
      const playersPath = path.join(staging, 'players.json');
      await atomicJson(playersPath, config.players.map(p => p.riot));
      const matches = [];
      for (const row of rows) {
        const rawFile = path.join(staging, `match_${row.id}.json`), digestFile = path.join(staging, `digest_${row.id}.json`);
        await atomicJson(rawFile, row.raw);
        try {
          await exec(process.env.PWSH_PATH || 'pwsh', ['-NoProfile', '-NonInteractive', '-File', fileURLToPath(new URL('./Build-MatchDigest.ps1', import.meta.url)), '-MatchPath', rawFile, '-PlayersPath', playersPath, '-OutPath', digestFile], { timeout: 60000, maxBuffer: 8 * 1024 * 1024, windowsHide: true });
        } catch { throw new Error('Digest build failed; previous card preserved. Check PowerShell 7 and source schema.'); }
        const digest = await readJson(digestFile);
        if (digest.match?.matchId !== row.id || !digest.squad?.some(p => config.players.some(x => x.riot.toLowerCase() === p.name?.toLowerCase()))) throw new Error('Digest identity mismatch.');
        matches.push({ id: row.id, started_at: new Date(row.epoch * 1000).toISOString(), digest });
      }
      const candidate = { fetched_at: new Date().toISOString(), hash: hash(matches), matches };
      await atomicJson(path.join(state, 'candidate.json'), candidate);
      await atomicJson(statusPath, { status: 'ok', runId, hash: candidate.hash, fetched_at: candidate.fetched_at });
      console.log(JSON.stringify({ status: 'ok', count: matches.length, matchIds: matches.map(m => m.id) }));
    } catch (e) {
      await atomicJson(statusPath, { status: 'failed', runId });
      throw e;
    }
  });
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main().catch(e => { console.error(e.message); process.exitCode = 1; });
