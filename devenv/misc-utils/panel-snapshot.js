#!/usr/bin/env node
// Snapshot the MATE bottom panel's dconf state (layout, applets, launchers)
// into panel-snapshots/, so a known-good config can be restored with
// panel-restore.js after the panel loses icons.
const { execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const SNAPSHOT_DIR = path.join(__dirname, 'panel-snapshots');
fs.mkdirSync(SNAPSHOT_DIR, { recursive: true });

const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
const outFile = process.argv[2]
  ? path.resolve(process.argv[2])
  : path.join(SNAPSHOT_DIR, `panel-${timestamp}.ini`);

const dump = execFileSync('dconf', ['dump', '/org/mate/panel/'], { encoding: 'utf8' });
fs.writeFileSync(outFile, dump);
console.log(`Snapshot written to ${outFile}`);
