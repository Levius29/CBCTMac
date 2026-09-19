// Loads the demo study as patient "Jane" through the local API and
// opens the welcome screen, where Jane's study is the first recent study.
// Clicking it plays the entering transition with sound; browsers only allow
// sound after a click, so the script does not open the study itself.
// Running it again reuses the demo that is already in the library. Needs a
// running server: `npm run demo` starts one first.
//
//   node scripts/demo.mjs [--no-open]
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import path from 'node:path';

const BASE = 'http://127.0.0.1:4173';
const ARCHIVE = path.join(
  import.meta.dirname,
  '..',
  'demo',
  'jane-head-mri.zip',
);
/** Written into the patient's notes, so a real patient called Jane is never reused. */
const MARKER = 'Demo study shipped with OpenMRI (demo/jane-head-mri.zip).';
const openBrowser = !process.argv.includes('--no-open');

async function api(route, options = {}) {
  const r = await fetch(BASE + route, options);
  const body = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(body.error || `${route}: HTTP ${r.status}`);
  return body;
}
const json = (method, body) => ({
  method,
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify(body),
});
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function waitFor(jobId, status, seconds) {
  let stage = '';
  for (let i = 0; i < seconds; i++) {
    const job = await api(`/api/library/imports/${jobId}`);
    if (job.stage !== stage) {
      stage = job.stage;
      console.log(`  ${stage}`);
    }
    if (job.status === status) return job;
    if (job.status === 'error') throw new Error(job.error || 'Import failed');
    await sleep(1000);
  }
  throw new Error(`The import did not reach "${status}" in time`);
}

function open(url) {
  if (!openBrowser) return;
  const opener =
    process.platform === 'darwin'
      ? 'open'
      : process.platform === 'win32'
        ? 'explorer'
        : 'xdg-open';
  const r = spawnSync(opener, [url], { stdio: 'ignore' });
  if (r.error || r.status) console.log(`Open ${url} in your browser.`);
}

async function main() {
  const health = await fetch(`${BASE}/api/health`)
    .then((r) => r.json())
    .catch(() => null);
  if (health?.app !== 'openmri') {
    console.error(
      'OpenMRI is not running on 127.0.0.1:4173. Run npm run demo, which starts it, or npm run up first.',
    );
    process.exit(1);
  }
  const library = await api('/api/library');
  const jane = library.patients.find((p) => p.notes === MARKER);
  const existing =
    jane && library.studies.find((s) => s.patient_id === jane.id);
  if (existing) {
    console.log('The demo study is already in the library.');
    return finish();
  }

  console.log('Importing the demo study as patient Jane.');
  const { id } = await api(
    '/api/library/imports',
    json('POST', { filename: path.basename(ARCHIVE) }),
  );
  try {
    await api(`/api/library/imports/${id}`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/zip' },
      body: readFileSync(ARCHIVE),
    });
    await waitFor(id, 'review', 300);
    await api(
      `/api/library/imports/${id}`,
      json('POST', {
        patient: jane ? { id: jane.id } : { name: 'Jane', notes: MARKER },
      }),
    );
    const done = await waitFor(id, 'complete', 900);
    return finish();
  } catch (error) {
    // Someone imported the same archive by hand under another name. That
    // copy is the demo; leave it alone and discard this draft.
    if (/already imported for another patient/.test(error.message)) {
      await api(`/api/library/imports/${id}`, { method: 'DELETE' }).catch(
        () => {},
      );
      console.log(
        'The demo archive is already in the library under another patient name. Open it from the library.',
      );
      console.log(`OpenMRI: ${BASE}/`);
      open(`${BASE}/`);
      return;
    }
    throw error;
  }
}

function finish() {
  console.log(
    `Jane's study is ready. Open ${BASE}/ and click Jane under Recent studies.`,
  );
  open(`${BASE}/`);
}

main().catch((error) => {
  console.error(`The demo could not be loaded: ${error.message}`);
  process.exit(1);
});
