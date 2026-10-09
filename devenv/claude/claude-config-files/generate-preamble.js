#!/usr/bin/env node
'use strict';
// Emits the mandatory role preamble for the SessionStart hook. Node (not python)
// so it runs unchanged on the host and inside the slim node:* container image.
//
// Reads LLM/COMMON/directives.md plus LLM/roles/<ROLE>.md, resolving the
// EXTENDS chain back to COMMON, and prints a hookSpecificOutput JSON blob
// whose additionalContext is a directive table built from each file's `##`
// sections. This is the single source of truth for role/directive
// resolution — CLAUDE.md tells the assistant to consume this output, not to
// re-derive it.
//
// Any missing file, missing EXTENDS declaration, or EXTENDS cycle is a
// misconfiguration, not a degraded-but-ok state: this exits 2 with a stderr
// diagnostic rather than silently falling back to a stub message, so a
// broken config surfaces to Claude (exit 2 feeds stderr back as context)
// instead of quietly disappearing.

const fs = require('fs');
const os = require('os');
const path = require('path');

const LLM_DIR = path.join(os.homedir(), '.claude', 'LLM');
const COMMON_FILE = path.join(LLM_DIR, 'COMMON', 'directives.md');
const ROLES_DIR = path.join(LLM_DIR, 'roles');
const MAX_CHAIN_HOPS = 20;

function fail(msg) {
  process.stderr.write(`CLAUDE ROLE CONFIG ERROR: ${msg}\n`);
  process.exit(2);
}

function parseSections(file) {
  const text = fs.readFileSync(file, 'utf8');
  const headerRe = /^##\s+(.+?)\s*$/gm;
  const matches = [...text.matchAll(headerRe)];
  return matches.map((m, i) => {
    const bodyStart = m.index + m[0].length;
    const bodyEnd = i + 1 < matches.length ? matches[i + 1].index : text.length;
    return { title: m[1].trim(), body: text.slice(bodyStart, bodyEnd) };
  });
}

function summarize(body, maxLen = 160) {
  const cleaned = body
    .split('\n')
    .map(l => l.trim())
    .filter(Boolean)
    .map(l => l.replace(/^[-*]\s+/, ''))
    .join(' ')
    .replace(/\s+/g, ' ')
    .trim();
  // A directive that leads with a bolded rule (**...**) is stating the
  // actionable part up front; prefer that over the raw head of the text,
  // since a rule buried after explanatory prose gets silently cut off by
  // the maxLen truncation below and never reaches the session preamble.
  const boldMatch = cleaned.match(/\*\*(.+?)\*\*/);
  const candidate = boldMatch ? boldMatch[1].trim() : cleaned;
  return candidate.length > maxLen ? candidate.slice(0, maxLen - 1) + '…' : candidate;
}

// No default here: session-start.sh is the sole owner of the "default to
// DEV" policy. An empty HOOK_ROLE means the caller skipped that resolution
// (e.g. this script was invoked directly) — that's a misconfiguration, not
// something to paper over.
const role = (process.env.HOOK_ROLE || '').trim();
if (!role) fail('HOOK_ROLE is unset or empty — this script must be invoked via session-start.sh, which resolves and exports it');

if (!fs.existsSync(COMMON_FILE)) {
  fail(`COMMON directives file missing: ${COMMON_FILE}`);
}

// Resolve the EXTENDS chain for `role`, COMMON first, leaf last.
const chain = [];
const visited = new Set();
let current = role;

while (true) {
  if (current === 'COMMON') {
    chain.unshift({ name: 'COMMON', file: COMMON_FILE });
    break;
  }
  if (visited.has(current)) {
    fail(`EXTENDS cycle detected: ${[...visited, current].join(' → ')}`);
  }
  if (visited.size >= MAX_CHAIN_HOPS) {
    fail(`EXTENDS chain exceeded ${MAX_CHAIN_HOPS} hops resolving role '${role}' — likely a cycle`);
  }
  visited.add(current);

  const file = path.join(ROLES_DIR, `${current}.md`);
  if (!fs.existsSync(file)) {
    fail(`Role file not found for '${current}': ${file}`);
  }
  chain.unshift({ name: current, file });

  const text = fs.readFileSync(file, 'utf8');
  const extendsM = text.match(/^EXTENDS:\s*(\S+)\s*$/m);
  if (!extendsM) {
    fail(`Role file '${file}' has no EXTENDS declaration — every role must extend COMMON, directly or transitively`);
  }
  current = extendsM[1];
}

const rows = [];
for (const { name, file } of chain) {
  for (const { title, body } of parseSections(file)) {
    const summary = summarize(body);
    if (summary) rows.push([title, name, summary]);
  }
}

if (rows.length === 0) {
  fail(`No directive sections ('##' headings) found across resolved chain for role '${role}': ${chain.map(c => c.file).join(', ')}`);
}

const pipe = s => s.replace(/\|/g, '\\|');
const table = [
  `Active role: ${role}`, '',
  '| Directive | Source | Summary |',
  '|---|---|---|',
  ...rows.map(([d, s, sm]) => `| ${pipe(d)} | ${pipe(s)} | ${pipe(sm)} |`),
].join('\n');

const additional =
  'MANDATORY SESSION PREAMBLE\n' +
  'Your first response MUST begin with the following block copied verbatim ' +
  '(do not paraphrase or reorder rows). Output it before addressing anything else:\n\n' +
  '---\n' + table + '\n---';

const output = {
  hookSpecificOutput: { hookEventName: 'SessionStart', additionalContext: additional },
};

// devenv status is for the human, not the model: it doesn't inform anything
// the assistant needs to reason about, so it goes out via `systemMessage`
// (terminal-only) rather than `additionalContext` (which would burn LLM
// context tokens and force the assistant to echo it back verbatim).
const devenvStatus = (process.env.HOOK_DEVENV_STATUS || '').trim();
if (devenvStatus) {
  output.systemMessage = '⚠️  Uncommitted devenv/ changes:\n' + devenvStatus;
}

process.stdout.write(JSON.stringify(output));
