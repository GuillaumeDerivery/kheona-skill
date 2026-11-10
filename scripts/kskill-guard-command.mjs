#!/usr/bin/env node
// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
// not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
// The part of a shell command the Claude hook checks (kskill-guard-hook.sh claude): stdin the command, stdout its
// text minus the pipelines that cannot carry data to a write. Prints nothing when nothing in it writes.
//
// The command is cut into pipelines at unquoted `;`, `&&`, `||`, `&` and newlines (a heredoc stays with its
// command, quotes and `$(...)` are never cut). A pipeline is left out only when it is inert: nothing in it writes,
// it redirects nothing (`>`, `tee`), assigns nothing, and each command in it is a reader (`cd`, `ls`, `grep`, a
// read-only git or gh...). Everything else stays, so a value set or produced before the write is still checked.
// When in doubt the text stays: a wrong cut only makes the check stricter.
import { readFileSync, realpathSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const WRITES =
  /(^|[;&|( ]|\$\()(git( -C [^ ]+)? (commit|tag|push|notes)|gh (pr (create|edit|comment|review|merge)|issue (create|edit|comment)|release (create|edit|upload)|repo (create|edit)|gist (create|edit)|label (create|edit)|api [^;&|]*(-X|--method) *(POST|PUT|PATCH)|api [^;&|]*( -f| -F| --field| --raw-field| --input)))/;
const READERS = new Set(
  'cd pushd popd ls cat grep egrep fgrep rg head tail wc jq yq sort uniq cut find stat file test [ [[ true false sleep pwd which command type diff git gh'.split(' '),
);
const KEYWORDS = new Set(['do', 'then', 'else', 'elif', '{', '(', '!', 'time']);

/** Cuts a command into pipelines; each keeps its own text, heredoc bodies included. */
export function pipelines(cmd) {
  const out = [];
  let cur = '';
  let quote = ''; // ' or " or `
  let depth = 0; // $( ... ) nesting
  const heredocs = [];
  const cut = () => {
    if (cur.trim()) out.push(cur);
    cur = '';
  };
  for (let i = 0; i < cmd.length; i++) {
    const c = cmd[i];
    if (quote) {
      cur += c;
      if (c === '\\' && quote !== "'") cur += cmd[++i] ?? '';
      else if (c === quote) quote = '';
      continue;
    }
    if (c === '\\') { cur += c + (cmd[++i] ?? ''); continue; }
    if (c === "'" || c === '"' || c === '`') { quote = c; cur += c; continue; }
    if (c === '$' && cmd[i + 1] === '(') { depth++; cur += '$('; i++; continue; }
    if (c === '(' && depth) { depth++; cur += c; continue; }
    if (c === ')' && depth) { depth--; cur += c; continue; }
    if (depth) { cur += c; continue; }
    if (c === '<' && cmd[i + 1] === '<' && cmd[i + 2] !== '<') {
      const m = /^<<(-?)\s*(['"]?)([\w.-]+)\2/.exec(cmd.slice(i));
      if (m) { heredocs.push({ tabs: m[1] === '-', end: m[3] }); cur += m[0]; i += m[0].length - 1; continue; }
    }
    if (c === '\n') {
      cur += c;
      while (heredocs.length) { // the bodies belong to the command that opened them
        const { tabs, end } = heredocs.shift();
        while (i + 1 < cmd.length) {
          const nl = cmd.indexOf('\n', i + 1);
          const line = cmd.slice(i + 1, nl < 0 ? cmd.length : nl);
          cur += line + (nl < 0 ? '' : '\n');
          i = nl < 0 ? cmd.length : nl;
          if ((tabs ? line.replace(/^\t+/, '') : line) === end) break;
        }
      }
      cut();
      continue;
    }
    if (c === ';' || (c === '&' && cmd[i + 1] !== '>' && cmd[i - 1] !== '>')) { cut(); if (cmd[i + 1] === '&') i++; continue; }
    if (c === '|' && cmd[i + 1] === '|') { cut(); i++; continue; }
    cur += c;
  }
  cut();
  return out;
}

/** The commands of a pipeline (cut at unquoted `|`), as their first words. */
function heads(p) {
  const words = [];
  let quote = '';
  let depth = 0;
  let start = true;
  let word = '';
  const flush = () => { if (start && word) { words.push(word); start = false; } word = ''; };
  for (let i = 0; i < p.length; i++) {
    const c = p[i];
    if (quote) { if (c === quote) quote = ''; else if (c === '\\' && quote !== "'") i++; word += c; continue; }
    if (c === "'" || c === '"' || c === '`') { quote = c; word += c; continue; }
    if (c === '$' && p[i + 1] === '(') { depth++; word += '$('; i++; continue; }
    if (depth) { if (c === '(') depth++; else if (c === ')') depth--; word += c; continue; }
    if (c === '|') { flush(); start = true; continue; }
    if (/\s/.test(c)) { if (start && KEYWORDS.has(word)) word = ''; else flush(); continue; }
    word += c;
  }
  flush();
  return words;
}

/** Whether a pipeline can neither write nor hand data to a write. */
export function inert(p) {
  if (WRITES.test(p)) return false;
  if (/(^|[^<>&0-9])>|(^|\s)tee(\s|$)/.test(p.replace(/'[^']*'|"(\\.|[^"\\])*"/g, ''))) return false;
  const hs = heads(p);
  return hs.length > 0 && hs.every((h) => READERS.has(h));
}

/** The text to check: empty when nothing writes. */
export function scope(cmd) {
  const ps = pipelines(cmd);
  if (!ps.some((p) => WRITES.test(p))) return '';
  return ps.filter((p) => !inert(p)).join('\n');
}

if (process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) process.stdout.write(scope(readFileSync(0, 'utf8')));
