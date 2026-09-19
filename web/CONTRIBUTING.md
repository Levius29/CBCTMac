# Contributing

Thanks for helping. OpenMRI is a small project; keep changes focused and
describe the user-visible effect in the pull request.

## Set up

```sh
npm ci
npm run setup   # Python virtualenv with pydicom, nibabel, SimpleITK, dcm2niix
npm run dev     # http://127.0.0.1:4173
```

## Before you open a pull request

```sh
npm run format       # oxfmt
npm run check        # lint, typecheck, Node tests
npm run test:import  # Python tests: ZIP import, dcm2niix conversion, registration
```

CI runs the same commands on Linux with Node 22 and Python 3.12 and 3.14, and
checks that `npm run demo` loads the demo study.

## Rules that matter here

- **No real medical data.** The demo study in `demo/` is the only
  scan in the repository, and it stays the only one. Nothing else from a real
  person goes into code, tests, fixtures, issues, screenshots, or commit
  messages. Tests generate synthetic DICOM and NIfTI data; keep it that way.
- **OpenMRI is a viewer.** Do not add features that detect, measure, or
  diagnose, and do not present registration or intensity values as a clinical
  result. The README's limitations section states what the app does not claim.
- **The server stays local.** Bind to `127.0.0.1`, no cloud calls, no telemetry,
  no analytics.
- **Keep dependencies minimal** and pinned. A new dependency needs a sentence
  on why the existing ones are not enough.
- Write commit messages that explain why, not only what.

## Reporting bugs

Open an issue with the template. Include your OS, Node and Python versions, and
what the import wizard or the worker log reported, with patient details
removed. See [SECURITY.md](SECURITY.md) for what must never be attached.
