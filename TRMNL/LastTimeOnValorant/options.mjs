import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { readJson, validateConfig } from './core.mjs';

export async function options(args = process.argv.slice(2)) {
  const root = fileURLToPath(new URL('./', import.meta.url));
  let configFile = path.join(root, 'config.local.json'), state = path.join(root, '.state'), input;
  let dryRun = false;
  for (let i = 0; i < args.length; i++) {
    const flag = args[i];
    if (flag === '--dry-run') { dryRun = true; continue; }
    if (!['--config', '--state', '--input'].includes(flag) || !args[i + 1] || args[i + 1].startsWith('--')) throw new Error('Use --config FILE, --state DIRECTORY, --input FILE and/or --dry-run.');
    const value = path.resolve(args[++i]);
    if (flag === '--config') configFile = value;
    if (flag === '--state') state = value;
    if (flag === '--input') input = value;
  }
  return { config: validateConfig(await readJson(configFile)), state, input: input || path.join(state, 'input.json'), dryRun };
}
