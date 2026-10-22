import fs from 'node:fs/promises';
import path from 'node:path';
import { createHash, randomUUID } from 'node:crypto';

export const hash = value => createHash('sha256').update(JSON.stringify(value)).digest('hex');
export const readJson = async file => JSON.parse((await fs.readFile(file, 'utf8')).replace(/^\uFEFF/, ''));
export async function atomicJson(file, value) {
  await fs.mkdir(path.dirname(file), { recursive: true });
  const temp = `${file}.${randomUUID()}.tmp`;
  try {
    await fs.writeFile(temp, JSON.stringify(value, null, 2) + '\n', { flag: 'wx', mode: 0o600 });
    await fs.rename(temp, file);
  } finally { await fs.rm(temp, { force: true }); }
}
export async function withLock(file, action) {
  await fs.mkdir(path.dirname(file), { recursive: true });
  let handle;
  try { handle = await fs.open(file, 'wx', 0o600); }
  catch (e) {
    if (e.code === 'EEXIST') throw new Error('Another run holds the lock. Inspect the process before removing a stale lock.');
    throw e;
  }
  try { await handle.writeFile(JSON.stringify({ pid: process.pid })); return await action(); }
  finally { await handle.close(); await fs.rm(file, { force: true }); }
}
export function text(value, max = 80) {
  return typeof value === 'string' && value.trim() && value.length <= max && !/[<>\x00-\x1f\u2014]|@everyone|@here/i.test(value);
}
export function validateConfig(config) {
  if (!Array.isArray(config?.players) || config.players.length !== 2) throw new Error('Configure exactly two players.');
  for (const [i, p] of config.players.entries()) {
    if (p.key !== `p${i + 1}` || !text(p.name, 35) || !text(p.riot, 80) || !/^[^#]+#[^#]+$/.test(p.riot)) throw new Error('Invalid player configuration.');
  }
  if (new Set(config.players.map(p => p.riot.toLowerCase())).size !== 2) throw new Error('Players must be distinct.');
  if (!/^(na|eu|ap|kr|latam|br)$/.test(config.region) || !Number.isInteger(config.scanSize) || config.scanSize < 1 || config.scanSize > 10) throw new Error('Invalid region or history size.');
  new Intl.DateTimeFormat('en-US', { timeZone: config.timezone }).format();
  return config;
}
export function validateTarget(target) {
  if (target?.projectId !== 'last-time-on-valorant' || !Number.isSafeInteger(target.pluginSettingId) || target.pluginSettingId <= 0 || !Number.isSafeInteger(target.deviceId) || target.deviceId <= 0) throw new Error('Set explicit positive plugin setting and device IDs in local configuration.');
  return target;
}
export function selectFinished(histories, config, now = Date.now()) {
  const tracked = new Set(config.players.map(p => p.riot.toLowerCase()));
  const found = new Map();
  for (const raw of histories.flat()) {
    if (!raw?.players?.all_players?.some(p => tracked.has(`${p.name}#${p.tag}`.toLowerCase()))) continue;
    const id = raw.metadata?.matchid;
    if (!/^[a-z0-9-]+$/i.test(id || '')) throw new Error('Unsafe match ID in source.');
    const start = Number(raw.metadata.game_start), duration = Number(raw.metadata.game_length);
    if (!Number.isFinite(start) || start <= 0 || !Number.isFinite(duration) || duration <= 0 || (start + duration) * 1000 > now) continue;
    if (found.has(id) && hash(found.get(id).raw) !== hash(raw)) throw new Error('Conflicting copies of a match; preserve the previous card.');
    found.set(id, { id, epoch: start, raw });
  }
  return [...found.values()].sort((a, b) => b.epoch - a.epoch || a.id.localeCompare(b.id)).slice(0, 3);
}
export function project(candidate, input, config, now = Date.now()) {
  validateConfig(config);
  const checked = Date.parse(candidate?.fetched_at);
  if (!Number.isFinite(checked) || checked > now + 60000 || now - checked > 7200000) throw new Error('Fetch fresh history before publishing.');
  if (!Array.isArray(candidate.matches) || candidate.matches.length > 3 || candidate.hash !== hash(candidate.matches)) throw new Error('Invalid candidate digest hash.');
  if (!Array.isArray(input?.matches) || input.matches.length !== candidate.matches.length || new Set(input.matches.map(m => m.id)).size !== input.matches.length) throw new Error('Commentary must cover every candidate exactly once.');
  const ids = candidate.matches.map(m => m.id);
  if (new Set(ids).size !== ids.length || input.matches.some(m => !ids.includes(m.id))) throw new Error('Commentary IDs do not match current candidates.');
  const dateLabel = iso => new Intl.DateTimeFormat('en-US', { timeZone: config.timezone, month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }).format(new Date(iso));
  const items = candidate.matches.map((m, index) => {
    const d = m.digest, narrative = input.matches.find(x => x.id === m.id);
    const started = Date.parse(m.started_at);
    if (!/^[a-z0-9-]+$/i.test(m.id) || d?.match?.matchId !== m.id || !Number.isFinite(started) || started > checked || (index && started > Date.parse(candidate.matches[index - 1].started_at))) throw new Error('Invalid match identity or ordering.');
    for (const [key, max] of [['headline', 55], ['commentary', 230], ['short', 130]]) if (!text(narrative[key], max)) throw new Error(`Invalid ${key}.`);
    if (!text(d.match.map) || !text(d.match.mode) || !Number.isFinite(d.match.durationMin) || d.match.durationMin <= 0 || !Array.isArray(d.squad)) throw new Error('Invalid digest metadata.');
    const players = config.players.map(({ key, name, riot }) => {
      const p = d.squad.find(x => x.name?.toLowerCase() === riot.toLowerCase());
      if (!p) return { key, name, present: false, agent: null, kills: null, deaths: null, assists: null, kda: null, acs: null, hs: null, clutches: null, team: null };
      for (const k of ['kills', 'deaths', 'assists', 'acs', 'hsPct', 'clutchesWon']) if (!Number.isFinite(p[k]) || p[k] < 0) throw new Error('Invalid digest player stat.');
      if (p.hsPct > 100 || !text(p.agent)) throw new Error('Invalid digest player metadata.');
      return { key, name, present: true, agent: p.agent, kills: p.kills, deaths: p.deaths, assists: p.assists, kda: `${p.kills}/${p.deaths}/${p.assists}`, acs: p.acs, hs: p.hsPct, clutches: p.clutchesWon, team: p.team };
    });
    const present = players.filter(p => p.present);
    if (!present.length) throw new Error('Candidate does not contain a tracked player.');
    const team = present[0].team, split = present.some(p => p.team !== team), score = d.result?.score;
    const winner = d.result?.winner, total = score?.blue + score?.red;
    // A surrender can have synthetic round entries beyond the reported score.
    // Show stats only when source fields disagree; never invent a replacement score.
    const usable = present.every(p => ['Blue', 'Red'].includes(p.team)) && ['blue', 'red'].every(k => Number.isInteger(score?.[k]) && score[k] >= 0) && total > 0 && total === d.match.roundsPlayed && ['Blue', 'Red', 'Draw'].includes(winner) && (winner === 'Draw' ? score.blue === score.red : score[winner.toLowerCase()] > score[winner === 'Blue' ? 'red' : 'blue']);
    const result = !usable ? 'Stats only' : split ? 'Split teams' : winner === 'Draw' ? 'Draw' : winner === team ? 'Win' : 'Loss';
    const ours = split ? score?.blue : score?.[String(team).toLowerCase()], theirs = split ? score?.red : score?.[team === 'Blue' ? 'red' : 'blue'];
    return { id: m.id, episode: String(index + 1).padStart(2, '0'), map: d.match.map, mode: d.match.mode, date: dateLabel(m.started_at), started_at: m.started_at, duration: d.match.durationMin, result, score: usable ? `${ours}-${theirs}` : 'N/A', score_label: usable && split ? 'Blue / Red' : '', headline: narrative.headline, commentary: narrative.commentary, short: narrative.short, players };
  });
  const payload = { status: items.length ? 'ok' : 'empty', source_hash: candidate.hash, content_hash: hash({ items, players: config.players.map(p => p.name), timezone: config.timezone }), checked_at: candidate.fetched_at, checked_label: dateLabel(candidate.fetched_at), timezone: config.timezone, players_label: config.players.map(p => p.name).join(' × '), player_names: config.players.map(p => p.name), items, wins: items.filter(m => m.result === 'Win').length, losses: items.filter(m => m.result === 'Loss').length };
  const bytes = Buffer.byteLength(JSON.stringify(payload));
  if (bytes > 5000) throw new Error('Payload exceeds 5 kB.');
  return { payload, bytes };
}
