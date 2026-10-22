import path from 'node:path';
import { pathToFileURL } from 'node:url';

// Only the existing TRMNL Control installation loads its stored OAuth credentials.
// This module is imported after projection, only for an explicit publish.
export function directClient(token, fetcher = fetch) {
  if (!token) throw new Error('Set a TRMNL account API token in TRMNL_API_KEY.');
  return { call: async (name, args) => {
    const id = args?.path?.plugin_setting_id || args?.path?.id;
    if (!/^[1-9][0-9]*$/.test(id || '')) throw new Error('Invalid plugin setting ID.');
    const routes = {
      getMergeVariables: ['GET', `merge_variables`],
      updatePluginSettingData: ['POST', `data`],
      startRefresh: ['POST', `refreshes`]
    };
    if (!routes[name]) throw new Error('Unsupported operation.');
    const [method, suffix] = routes[name];
    let response;
    try {
      response = await fetcher(`https://trmnl.com/api/plugin_settings/${id}/${suffix}`, {
        method, headers: { Accept: 'application/json', Authorization: `Bearer ${token}`, ...(args.body ? { 'Content-Type': 'application/json' } : {}) },
        body: args.body ? JSON.stringify(args.body) : undefined,
        redirect: 'error', signal: AbortSignal.timeout(20000)
      });
    } catch { throw new Error('TRMNL connection failed; reconcile before retrying.'); }
    let data;
    try { data = await response.json(); } catch { throw new Error('Invalid TRMNL response; reconcile before retrying.'); }
    if (!response.ok || Number(data.status) >= 400) {
      const error = new Error('TRMNL request failed; reconcile before retrying.');
      error.status = response.ok ? data.status : response.status;
      error.retryAfter = response.headers.get('retry-after');
      throw error;
    }
    return { status: response.status, data };
  } };
}
export async function connect() {
  const root = process.env.TRMNL_CONTROL_ROOT;
  if (!root) return directClient(process.env.TRMNL_API_KEY);
  if (!path.isAbsolute(root)) throw new Error('Set TRMNL_CONTROL_ROOT to an installed TRMNL Control checkout.');
  const configModule = await import(pathToFileURL(path.join(root, 'src', 'config.mjs')));
  const { createContext } = await import(pathToFileURL(path.join(root, 'src', 'server.mjs')));
  const ctx = createContext(await configModule.loadConfig());
  return { call: (name, args) => ctx.client.execute(name, args) };
}
