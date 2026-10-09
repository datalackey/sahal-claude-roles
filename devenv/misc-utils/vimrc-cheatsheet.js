#!/usr/bin/env node
const fs = require('fs');
const path = require('path');

const vimrcPath = process.argv[2] || path.join(process.env.HOME, '.vimrc');
const realPath = fs.existsSync(vimrcPath) ? fs.realpathSync(vimrcPath) : vimrcPath;
const lines = fs.readFileSync(realPath, 'utf8').split('\n');

const MODE_LABELS = {
  map: 'n/v/o',    nmap: 'normal',   vmap: 'visual',  imap: 'insert',
  xmap: 'visual',  omap: 'operator', noremap: 'n/v/o', nnoremap: 'normal',
  vnoremap: 'visual', inoremap: 'insert', xnoremap: 'visual', cnoremap: 'command',
};

const rows = [];
let lastComment = '';
let prevWasComment = false;

for (const line of lines) {
  const t = line.trim();
  if (!t) { prevWasComment = false; continue; }
  if (t.startsWith('"')) {
    lastComment = t.replace(/^["\s]+/, '');
    prevWasComment = true;
    continue;
  }
  const m = t.match(/^:?([a-z]*(?:nore)?map)\s+(\S+)\s+(.*)/);
  if (m) {
    const [, cmd, key, action] = m;
    rows.push({
      mode: MODE_LABELS[cmd] || cmd,
      key,
      desc: prevWasComment ? lastComment : '',
      action: action.trim(),
    });
  }
  prevWasComment = false;
  lastComment = '';
}

const colW = k => Math.max(k.length, ...rows.map(r => String(r[k]).length));
const wMode = colW('mode'), wKey = colW('key'), wDesc = colW('desc');
const pad = (s, n) => String(s).padEnd(n);
const hr = `${'-'.repeat(wMode)}-+-${'-'.repeat(wKey)}-+-${'-'.repeat(wDesc)}-+-${'─'.repeat(36)}`;

console.log('\n  Vim Custom Key Bindings\n');
console.log(`${pad('Mode', wMode)} | ${pad('Key', wKey)} | ${pad('Description', wDesc)} | Action`);
console.log(hr);
for (const r of rows) {
  console.log(`${pad(r.mode, wMode)} | ${pad(r.key, wKey)} | ${pad(r.desc, wDesc)} | ${r.action}`);
}
console.log();
