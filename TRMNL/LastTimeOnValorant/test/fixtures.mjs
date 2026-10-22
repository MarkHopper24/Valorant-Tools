import { hash } from '../core.mjs';

// Entirely fictional data. No account IDs, real match IDs, or production statistics.
export const config = {
  players: [{ key: 'p1', name: 'Player One', riot: 'ExampleOne#DEMO' }, { key: 'p2', name: 'Player Two', riot: 'ExampleTwo#DEMO' }],
  region: 'na', scanSize: 10, timezone: 'America/Chicago',
  target: { projectId: 'last-time-on-valorant', pluginSettingId: 123, deviceId: 456 }
};
export function fixture(now = Date.now()) {
  const names = ['Ascent', 'Split', 'Gauntlet'];
  const matches = names.map((map, i) => ({
    id: `demo-${3 - i}`, started_at: new Date(now - (i + 1) * 3600000).toISOString(),
    digest: {
      match: { matchId: `demo-${3 - i}`, map, mode: i === 2 ? 'Gauntlet: Glitched' : 'Competitive', durationMin: i === 2 ? 15 : 30, roundsPlayed: i === 2 ? 16 : 20 },
      result: { winner: i === 2 ? 'Draw' : 'Red', score: { blue: i === 2 ? 0 : 7, red: i === 2 ? 0 : 13 } },
      squad: config.players.slice(0, i === 1 ? 1 : 2).map((p, j) => ({ name: p.riot, agent: i === 2 ? 'Unknown' : j ? 'Sage' : 'Cypher', team: i === 2 ? 'Team_3' : 'Red', kills: 18 - i - j, deaths: 12, assists: 5 + j, acs: 220 - i * 10 - j * 15, hsPct: 15, clutchesWon: 0 })),
      rounds: [], highlights: {}
    }
  }));
  const candidate = { fetched_at: new Date(now).toISOString(), hash: hash(matches), matches };
  const input = { matches: matches.map((m, i) => ({ id: m.id, headline: `${m.digest.match.map} demo recap`, commentary: i === 1 ? 'Player One finished with 17 kills, 12 deaths and 5 assists in a 13-7 win.' : i === 2 ? 'Player One recorded 16 kills and Player Two 15. Team result unavailable for this mode.' : 'Player One finished with 18 kills; Player Two added 17 kills and 6 assists in a 13-7 win.', short: i === 1 ? 'Player One: 17/12/5 in a 13-7 win.' : i === 2 ? 'Player One: 16 kills. Player Two: 15 kills. Stats only.' : 'Player One: 18 kills. Player Two: 17 kills. A 13-7 win.' })) };
  return { candidate, input, config: structuredClone(config) };
}
