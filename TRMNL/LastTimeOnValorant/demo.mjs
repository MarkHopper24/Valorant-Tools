import { fixture } from './test/fixtures.mjs';
import { project } from './core.mjs';

// Prints fictional merge variables for layout previews. No credentials or network.
const { candidate, input, config } = fixture();
console.log(JSON.stringify(project(candidate, input, config).payload, null, 2));
