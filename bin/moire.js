#!/usr/bin/env node
// Launcher for the npm distribution. The tool itself is bin/moire — a single
// Python 3.8 file with no dependencies. This wrapper exists only so `npm i -g`
// puts `moire` on PATH and so a missing interpreter produces a clear message
// instead of a shebang error.
//
// It must stay transparent: the child's exit code is propagated verbatim,
// because `moire check` and `moire verify` deliberately always exit 0 and
// nothing here may change that.

'use strict';

const { spawnSync } = require('child_process');
const path = require('path');
const fs = require('fs');

const script = path.join(__dirname, 'moire');

if (!fs.existsSync(script)) {
  process.stderr.write('moire: missing ' + script + '\n');
  process.exit(2);
}

// MOIRE_PYTHON wins if set; otherwise try the usual names in order.
const candidates = process.env.MOIRE_PYTHON
  ? [process.env.MOIRE_PYTHON]
  : ['python3', 'python3.12', 'python3.11', 'python3.10', 'python3.9', 'python3.8', 'python'];

function usable(exe) {
  const probe = spawnSync(exe, ['-c', 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)'],
                          { stdio: 'ignore' });
  return probe.status === 0;
}

let python = null;
for (const exe of candidates) {
  if (usable(exe)) { python = exe; break; }
}

if (!python) {
  process.stderr.write(
    'moire: needs Python 3.8 or newer on PATH.\n' +
    '    Tried: ' + candidates.join(', ') + '\n' +
    '    Set MOIRE_PYTHON=/path/to/python3 to point at a specific interpreter.\n');
  process.exit(2);
}

const run = spawnSync(python, [script].concat(process.argv.slice(2)), { stdio: 'inherit' });

if (run.error) {
  process.stderr.write('moire: failed to start ' + python + ': ' + run.error.message + '\n');
  process.exit(2);
}

// Preserve signal-terminated exits rather than reporting them as success.
if (run.signal) {
  process.kill(process.pid, run.signal);
}

process.exit(run.status === null ? 2 : run.status);
