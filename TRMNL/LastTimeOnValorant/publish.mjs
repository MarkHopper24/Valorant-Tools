import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { atomicJson, project, readJson, validateTarget, withLock } from './core.mjs';
import { options } from './options.mjs';

const variables = response => response?.data?.data?.variables;
export async function publish({ payload, bytes, target, call, save }) {
  validateTarget(target);
  const id = String(target.pluginSettingId);
  const remote = await call('getMergeVariables', { path: { plugin_setting_id: id } });
  const current = variables(remote);
  if (!current || typeof current !== 'object') throw new Error('Invalid remote readback; no write attempted.');
  const elapsed = Date.parse(payload.checked_at) - Date.parse(current.checked_at);
  if (current.content_hash === payload.content_hash && elapsed >= 0 && elapsed < 55 * 60000) return { skipped: true, verified: true, reason: 'Already checked this hour.' };
  if (Date.parse(current.checked_at) > Date.parse(payload.checked_at)) throw new Error('Remote check is newer; fetch again before publishing.');
  // Never retry a mutation here, including HTTP 429 or uncertain network outcomes.
  const accepted = await call('updatePluginSettingData', { path: { id }, body: { merge_variables: payload } });
  if (accepted.status < 200 || accepted.status >= 300) throw new Error('Publish was not confirmed; reconcile remote variables before retrying.');
  const receipt = { ...target, accepted_at: new Date().toISOString(), checked_at: payload.checked_at, content_hash: payload.content_hash, matchIds: payload.items.map(m => m.id), bytes, httpStatus: accepted.status, verified: false };
  await save(payload, receipt);
  // Read back before requesting a render, so render failure cannot hide acceptance.
  const check = variables(await call('getMergeVariables', { path: { plugin_setting_id: id } }));
  if (check?.content_hash !== payload.content_hash || check?.checked_at !== payload.checked_at) throw new Error('Readback mismatch; reconcile before retrying.');
  receipt.verified = true;
  await save(payload, receipt);
  try { receipt.refresh = (await call('startRefresh', { path: { plugin_setting_id: id } })).data; }
  catch { receipt.renderPending = true; await save(payload, receipt); throw new Error('Data accepted and verified; rendering failed. Request only startRefresh for the configured plugin.'); }
  await save(payload, receipt);
  return receipt;
}
async function main() {
  const { config, state, input, dryRun } = await options();
  // Hold the fetch lock through projection/publication to prevent another run replacing it.
  await withLock(path.join(state, 'fetch.lock'), async () => {
    const candidate = await readJson(path.join(state, 'candidate.json'));
    const status = await readJson(path.join(state, 'fetch-status.json'));
    if (status.status !== 'ok' || status.hash !== candidate.hash || status.fetched_at !== candidate.fetched_at) throw new Error('Latest fetch did not succeed; preserve previous card.');
    const { payload, bytes } = project(candidate, await readJson(input), config);
    if (dryRun) { console.log(JSON.stringify({ dryRun: true, bytes, payload })); return; }
    const target = validateTarget(config.target);
    const { connect } = await import('./control.mjs');
    const { call } = await connect();
    await withLock(path.join(state, 'publish.lock'), async () => {
      let previous;
      try { previous = await readJson(path.join(state, 'last-receipt.json')); } catch (e) { if (e.code !== 'ENOENT') throw e; }
      if (previous && (previous.pluginSettingId !== target.pluginSettingId || previous.deviceId !== target.deviceId || previous.projectId !== target.projectId)) throw new Error('Target differs from receipt. Use a separate state directory for a different target.');
      const result = await publish({ payload, bytes, target, call, save: async (data, receipt) => {
        await atomicJson(path.join(state, 'last-payload.json'), data);
        await atomicJson(path.join(state, 'last-receipt.json'), receipt);
      } });
      console.log(JSON.stringify(result));
    });
  });
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main().catch(e => {
  // Third-party errors can include request headers. Never print those objects/messages.
  if (e.status) console.error(JSON.stringify({ error: 'TRMNL request failed. Reconcile before retrying a write.', httpStatus: e.status, retryAfter: /^\d+$/.test(String(e.retryAfter)) ? Number(e.retryAfter) : undefined }));
  else console.error('Publish failed. Preserve the card, inspect local setup/receipt, and reconcile remote variables before retrying.');
  process.exitCode = 1;
});
