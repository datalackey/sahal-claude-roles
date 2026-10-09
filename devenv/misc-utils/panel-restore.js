#!/usr/bin/env node
// Restore the MATE bottom panel's dconf state from a snapshot made by
// panel-snapshot.js.
const { execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const SNAPSHOT_DIR = path.join(__dirname, 'panel-snapshots');
const file = process.argv[2];

if (!file) {
  console.error('Usage: panel-restore.js <snapshot-file>');
  const available = fs.existsSync(SNAPSHOT_DIR) ? fs.readdirSync(SNAPSHOT_DIR).sort() : [];
  if (available.length) {
    console.error('\nAvailable snapshots in panel-snapshots/:');
    available.forEach((f) => console.error(`  ${f}`));
  }
  process.exit(1);
}

const resolved = fs.existsSync(file) ? file : path.join(SNAPSHOT_DIR, file);
if (!fs.existsSync(resolved)) {
  console.error(`Snapshot file not found: ${file}`);
  process.exit(1);
}

const ini = fs.readFileSync(resolved, 'utf8');
execFileSync('dconf', ['load', '/org/mate/panel/'], { input: ini, stdio: ['pipe', 'inherit', 'inherit'] });
console.log(`Restored panel state from ${resolved}`);
