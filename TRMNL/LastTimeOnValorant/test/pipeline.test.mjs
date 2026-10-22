import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';
import { fixture, config } from './fixtures.mjs';
import { hash, project, selectFinished, withLock } from '../core.mjs';
import { fetchHistory } from '../fetch.mjs';
import { publish } from '../publish.mjs';
import { directClient } from '../control.mjs';

const exec = promisify(execFile), root = fileURLToPath(new URL('../', import.meta.url));
const rehash = c => { c.hash = hash(c.matches); return c; };
const render = f => project(f.candidate, f.input, f.config);

test('projection preserves facts, Chicago dates, mode limitations and missing-player nulls', () => {
  const f = fixture(Date.parse('2026-01-02T02:00:00Z'));
  const { payload, bytes } = project(f.candidate, f.input, f.config, Date.parse(f.candidate.fetched_at));
  assert.equal(payload.items[0].date, 'Jan 1, 7:00 PM');
  assert.equal(payload.items[0].score, '13-7');
  assert.equal(payload.items[1].players[1].deaths, null);
  assert.equal(payload.items[1].players[1].kills, null);
  assert.equal(payload.items[2].result, 'Stats only');
  assert.equal(payload.items[2].score, 'N/A');
  assert.ok(bytes < 5000);
});
test('draws, split teams, and inconsistent surrender scores are distinguished', () => {
  const f = fixture(), d = f.candidate.matches[0].digest;
  d.result = { winner: 'Draw', score: { blue: 14, red: 14 } }; d.match.roundsPlayed = 28;
  rehash(f.candidate); assert.equal(render(f).payload.items[0].result, 'Draw');
  d.squad[1].team = 'Blue'; rehash(f.candidate);
  assert.equal(render(f).payload.items[0].result, 'Split teams');
  d.result = { winner: 'Blue', score: { blue: 6, red: 4 } }; d.match.roundsPlayed = 19; rehash(f.candidate);
  assert.equal(render(f).payload.items[0].score, 'N/A');
  assert.equal(render(f).payload.items[0].result, 'Stats only');
});
test('stale, future, tampered, misordered, duplicate and untracked candidates fail closed', () => {
  for (const change of [
    f => { f.candidate.fetched_at = 'invalid'; },
    f => { f.candidate.fetched_at = new Date(Date.now() - 7200001).toISOString(); },
    f => { f.candidate.fetched_at = new Date(Date.now() + 120000).toISOString(); },
    f => { f.candidate.matches[0].digest.squad[0].kills++; },
    f => { f.candidate.matches.reverse(); rehash(f.candidate); },
    f => { f.candidate.matches[1] = f.candidate.matches[0]; rehash(f.candidate); },
    f => { f.candidate.matches[0].digest.squad = []; rehash(f.candidate); }
  ]) { const f = fixture(); change(f); assert.throws(() => render(f)); }
});
test('commentary must match the exact candidate set and reject markup/pings/oversize prose', () => {
  for (const change of [
    f => f.input.matches.pop(),
    f => { f.input.matches[0].id = 'old'; },
    f => { f.input.matches[1] = f.input.matches[0]; },
    f => { f.input.matches[0].commentary = 'x'.repeat(231); },
    f => { f.input.matches[0].headline = '<script>alert(1)</script>'; },
    f => { f.input.matches[0].short = '@everyone'; },
    f => { f.input.matches[0].short = 'Bad\u2014punctuation'; }
  ]) { const f = fixture(); change(f); assert.throws(() => render(f)); }
});
test('empty source produces an empty card, and nonfinite stats are rejected', () => {
  const f = fixture(); f.candidate.matches = []; rehash(f.candidate); f.input.matches = [];
  assert.equal(render(f).payload.status, 'empty');
  const g = fixture(); g.candidate.matches[0].digest.squad[0].kills = -1; rehash(g.candidate);
  assert.throws(() => render(g));
});
test('selection unions histories, deduplicates, filters unrelated/unfinished matches and sorts UTC', () => {
  const now = Date.now();
  const row = (id, age, tracked = true) => ({ metadata: { matchid: id, game_start: now / 1000 - age, game_length: 100 }, players: { all_players: [{ name: tracked ? 'ExampleOne' : 'Stranger', tag: 'DEMO' }] } });
  const a = row('a', 600), b = row('b', 900);
  assert.deepEqual(selectFinished([[b, a, row('future', 5)], [a, row('x', 500, false), row('c', 1200), row('d', 1500)]], config, now).map(x => x.id), ['a', 'b', 'c']);
  assert.throws(() => selectFinished([[a], [{ ...a, metadata: { ...a.metadata, game_length: 200 } }]], config, now), /Conflicting/);
  assert.throws(() => selectFinished([[row('../unsafe', 500)]], config, now), /Unsafe/);
});
test('history fetch fails on partial errors and never returns remote error bodies or credentials', async () => {
  let count = 0;
  const seen = [];
  const fake = async (url, opts) => {
    seen.push({ url, redirect: opts.redirect });
    return ++count === 1 ? new Response(JSON.stringify({ status: 200, data: [] })) : new Response('private error body', { status: 429, headers: { 'retry-after': '90' } });
  };
  await assert.rejects(fetchHistory(config, 'fictional-test-credential', fake), e => /429.*Retry after 90/.test(e.message) && !/private|credential/.test(e.message));
  assert.equal(count, 2); assert.ok(seen.every(x => x.redirect === 'error' && new URL(x.url).hostname === 'api.henrikdev.xyz'));
  await assert.rejects(fetchHistory(config, '', fake), /HENRIK_API_KEY/);
});
function remoteHarness(current = {}, fail) {
  const calls = [], receipts = [];
  const call = async (name, args) => {
    calls.push(name);
    if (name === fail) throw new Error('simulated failure');
    if (name === 'getMergeVariables') return { data: { data: { variables: current } } };
    if (name === 'updatePluginSettingData') { current = args.body.merge_variables; return { status: 200 }; }
    if (name === 'startRefresh') return { data: { status: 'queued' } };
    throw new Error('Unexpected operation');
  };
  return { call, calls, receipts, save: async (p, r) => receipts.push(structuredClone(r)) };
}
test('publication writes once, verifies readback and only refreshes the configured setting', async () => {
  const f = fixture(), h = remoteHarness();
  const r = await publish({ ...render(f), target: config.target, ...h });
  assert.equal(r.verified, true); assert.deepEqual(h.calls, ['getMergeVariables', 'updatePluginSettingData', 'getMergeVariables', 'startRefresh']);
});
test('duplicate publication skips, while a newer remote timestamp prevents overwrites', async () => {
  const f = fixture(), p = render(f), h = remoteHarness(p.payload);
  assert.equal((await publish({ ...p, target: config.target, ...h })).skipped, true);
  assert.deepEqual(h.calls, ['getMergeVariables']);
  const newer = remoteHarness({ checked_at: new Date(Date.now() + 60000).toISOString() });
  await assert.rejects(publish({ ...p, target: config.target, ...newer }), /newer/);
  assert.deepEqual(newer.calls, ['getMergeVariables']);
});
test('unconfirmed writes are not retried, and render failures retain verified receipts', async () => {
  const f = fixture(), p = render(f), failed = remoteHarness({}, 'updatePluginSettingData');
  await assert.rejects(publish({ ...p, target: config.target, ...failed }));
  assert.equal(failed.calls.filter(n => n === 'updatePluginSettingData').length, 1);
  const rendering = remoteHarness({}, 'startRefresh');
  await assert.rejects(publish({ ...p, target: config.target, ...rendering }), /Data accepted and verified/);
  assert.equal(rendering.receipts.at(-1).verified, true); assert.equal(rendering.receipts.at(-1).renderPending, true);
  const target = remoteHarness();
  await assert.rejects(publish({ ...p, target: { ...config.target, pluginSettingId: 0 }, ...target }));
  assert.equal(target.calls.length, 0);
});
test('direct adapter restricts routes and redirects, surfaces rate limits without remote bodies', async () => {
  const calls = [];
  const { call } = directClient('fictional-test-credential', async (url, options) => {
    calls.push({ url, options });
    return new Response(JSON.stringify({ message: 'private server details' }), { status: 429, headers: { 'retry-after': '120' } });
  });
  await assert.rejects(call('getMergeVariables', { path: { plugin_setting_id: '123' } }), e => e.status === 429 && e.retryAfter === '120' && !e.message.includes('private'));
  assert.equal(calls[0].url, 'https://trmnl.com/api/plugin_settings/123/merge_variables');
  assert.equal(calls[0].options.redirect, 'error');
  await assert.rejects(call('deletePluginSetting', { path: { id: '123' } }));
  await assert.rejects(call('startRefresh', { path: { plugin_setting_id: '../other' } }));
  assert.equal(calls.length, 1);
});
test('standalone PowerShell digest builder works with fictional input and no config/Discord state', async () => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'valorant-digest-'));
  try {
    const all = config.players.map((p, i) => ({ puuid: `demo-player-${i}`, name: p.riot.split('#')[0], tag: 'DEMO', team: 'Red', character: i ? 'Sage' : 'Cypher', currenttier_patched: 'Unrated', stats: { kills: i ? 1 : 2, deaths: 0, assists: 1, score: i ? 100 : 200, headshots: 1, bodyshots: 3, legshots: 0 }, damage_made: 100 }));
    const raw = { metadata: { matchid: 'demo-builder', map: 'Ascent', mode: 'Unrated', queue: 'Standard', region: 'na', game_length: 100, game_start_patched: 'Fictional demo', rounds_played: 1 }, players: { all_players: all }, teams: { blue: { rounds_won: 0, has_won: false }, red: { rounds_won: 1, has_won: true } }, kills: [], rounds: [{ winning_team: 'Red', end_type: 'Eliminated', bomb_planted: false, bomb_defused: false, plant_events: null, player_stats: all.map(p => ({ player_puuid: p.puuid, kills: p.stats.kills, economy: { loadout_value: 800 } })) }] };
    await fs.writeFile(path.join(dir, 'raw.json'), JSON.stringify(raw));
    await fs.writeFile(path.join(dir, 'players.json'), JSON.stringify(config.players.map(p => p.riot)));
    await exec(process.env.PWSH_PATH || 'pwsh', ['-NoProfile', '-NonInteractive', '-File', path.join(root, 'Build-MatchDigest.ps1'), '-MatchPath', path.join(dir, 'raw.json'), '-PlayersPath', path.join(dir, 'players.json'), '-OutPath', path.join(dir, 'digest.json')]);
    const digest = JSON.parse((await fs.readFile(path.join(dir, 'digest.json'), 'utf8')).replace(/^\uFEFF/, ''));
    assert.equal(digest.match.matchId, 'demo-builder'); assert.equal(digest.squad.length, 2);
    assert.equal(digest.squad[0].kills, 2); assert.equal(digest.result.ourResult, 'Win');
    assert.deepEqual((await fs.readdir(dir)).sort(), ['digest.json', 'players.json', 'raw.json']);
  } finally {
    assert.equal(path.dirname(path.resolve(dir)).toLowerCase(), path.resolve(os.tmpdir()).toLowerCase());
    assert.ok(path.basename(dir).startsWith('valorant-digest-'));
    await fs.rm(dir, { recursive: true, force: true });
  }
});
test('CLI dry run is offline, loads no OAuth adapter, and refuses the candidate after a failed fetch', async () => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'valorant-demo-'));
  try {
    const f = fixture();
    for (const [file, data] of Object.entries({ 'config.json': f.config, 'candidate.json': f.candidate, 'input.json': f.input, 'fetch-status.json': { status: 'ok', hash: f.candidate.hash, fetched_at: f.candidate.fetched_at } })) await fs.writeFile(path.join(dir, file), JSON.stringify(data));
    const args = [path.join(root, 'publish.mjs'), '--state', dir, '--config', path.join(dir, 'config.json'), '--dry-run'];
    const { stdout } = await exec(process.execPath, args, { env: { ...process.env, TRMNL_CONTROL_ROOT: path.join(dir, 'does-not-exist') } });
    assert.equal(JSON.parse(stdout).dryRun, true);
    await fs.writeFile(path.join(dir, 'fetch-status.json'), '{"status":"failed"}');
    await assert.rejects(exec(process.execPath, args));
    await assert.rejects(fs.access(path.join(dir, 'last-receipt.json')));
    await withLock(path.join(dir, 'exclusive.lock'), async () => { await assert.rejects(withLock(path.join(dir, 'exclusive.lock'), () => {}), /holds the lock/); });
  } finally {
    assert.equal(path.dirname(path.resolve(dir)).toLowerCase(), path.resolve(os.tmpdir()).toLowerCase());
    assert.ok(path.basename(dir).startsWith('valorant-demo-'));
    await fs.rm(dir, { recursive: true, force: true });
  }
});
