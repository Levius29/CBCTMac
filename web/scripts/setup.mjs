// Prepares the local processing environment: a Python virtualenv (3.12, 3.13
// or 3.14) with pydicom, nibabel, SimpleITK and the dcm2niix converter.
// Node.js and npm are assumed to be installed already. OPENMRI_SETUP_PYTHON
// names a specific interpreter to use instead of searching for one.
import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import path from 'node:path';

const windows = process.platform === 'win32';
const venvBin = path.join('.venv', windows ? 'Scripts' : 'bin');
const python = path.join(venvBin, windows ? 'python.exe' : 'python');
const converter = path.join(venvBin, windows ? 'dcm2niix.exe' : 'dcm2niix');

function run(cmd, args) {
  const r = spawnSync(cmd, args, { stdio: 'inherit' });
  if (r.status !== 0) process.exit(r.status || 1);
}
/** dcm2niix prints its banner but exits non-zero for --version, so match the output. */
function converterWorks(cmd) {
  const r = spawnSync(cmd, ['--version'], { encoding: 'utf8' });
  return !r.error && /dcm2nii/i.test(`${r.stdout ?? ''}${r.stderr ?? ''}`);
}
/** The pinned wheels are tested on these versions; see scripts/requirements.txt. */
const SUPPORTED = ['3.12', '3.13', '3.14'];
function findPython() {
  const explicit = process.env.OPENMRI_SETUP_PYTHON;
  const candidates = explicit
    ? [[explicit, []]]
    : windows
      ? [...SUPPORTED.map((v) => ['py', [`-${v}`]]), ['python', []]]
      : [...SUPPORTED.map((v) => [`python${v}`, []]), ['python3', []]];
  for (const [cmd, args] of candidates) {
    const r = spawnSync(cmd, [...args, '--version'], { encoding: 'utf8' });
    const version = /Python (3\.\d+)\./.exec(`${r.stdout}${r.stderr}`)?.[1];
    if (!r.error && SUPPORTED.includes(version)) return [cmd, args];
  }
  return null;
}

if (!existsSync(python)) {
  const found = findPython();
  if (!found) {
    console.error(
      `OpenMRI needs Python ${SUPPORTED.slice(0, -1).join(', ')} or ${SUPPORTED.at(-1)}, and none was found. Install one (on macOS: brew install python@3.12, otherwise https://www.python.org/downloads/) and rerun npm run setup.`,
    );
    process.exit(1);
  }
  run(found[0], [...found[1], '-m', 'venv', '.venv']);
}
run(python, ['-m', 'pip', 'install', '--upgrade', 'pip']);
run(python, [
  '-m',
  'pip',
  'install',
  '--only-binary=:all:',
  '-r',
  'scripts/requirements.txt',
]);
if (converterWorks(converter)) {
  console.log('dcm2niix is available from the virtualenv.');
} else if (converterWorks('dcm2niix')) {
  console.log('dcm2niix is available on PATH.');
} else {
  console.error(
    'dcm2niix was not found. Install it with your package manager (for example "brew install dcm2niix") and rerun npm run setup.',
  );
  process.exit(1);
}
console.log('The local MRI processing environment is ready.');
