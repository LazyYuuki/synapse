import assert from 'node:assert/strict';
import { promises as fs } from 'node:fs';
import path from 'node:path';

const sourceFiles = await filesUnder('src');
sourceFiles.push('vite.config.ts');
const builtFiles = await filesUnder('dist');
const source = await contents(sourceFiles);
const built = await contents(builtFiles);

for (const [label, forbidden] of [
  ['Tokamak key', /tokamak_api_key/i],
  ['Vite environment access', /import\.meta\.env|loadEnv|\bVITE_[A-Z0-9_]+/i],
  ['health request', /\/health\b/i],
  ['authorization field', /["']?authorization["']?\s*[:=]/i],
  ['API key field', /api[_-]?key|apiKey/i],
  ['Provider credential field', /provider[_-]?credentials?|tokamak[_-]?credentials?/i],
  ['bearer value', /bearer\s+[a-z0-9._-]+/i],
]) {
  assert.equal(forbidden.test(source), false, `frontend source contains forbidden token: ${label}`);
  forbidden.lastIndex = 0;
  assert.equal(forbidden.test(built), false, `production build contains forbidden token: ${label}`);
}

for (const forbidden of [
  'SYNAPSE_WEB_FIXTURE',
  'Synapse.WebFixture',
  'ControlledFake',
  'Provider.Fake',
  'Workspace.Fake',
  '__releaseTerminal',
  'ScriptedWebSocketServer',
  'RealSynapseServer',
]) {
  assert.equal(
    built.includes(forbidden),
    false,
    `production build contains test authority: ${forbidden}`,
  );
}

assert.equal(source.includes('proxy:'), false, 'Vite configuration must not define a proxy');

async function filesUnder(root) {
  const entries = await fs.readdir(root, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const file = path.join(root, entry.name);
    if (entry.isDirectory()) files.push(...(await filesUnder(file)));
    else if (entry.isFile()) files.push(file);
  }
  return files;
}

async function contents(files) {
  return (await Promise.all(files.map((file) => fs.readFile(file, 'utf8')))).join('\n');
}
