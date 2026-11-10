// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
// not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
// Renovate's post-upgrade step on a kheona-skill PR: once Renovate moved the callers' pins, writes the callers again
// with the generator of the version they now name (scripts/kskill-callers.mjs write, fetched at that commit), so a
// caller whose content changes with a version arrives right in the same PR. Run from the repository root.
// kskill-renovate-plan.sh inlines this file as the command (node --input-type=module -e '...') and allows exactly that
// command: the comment lines are dropped and the rest joined on one line, so every statement ends with a semicolon,
// and the code holds no single quote and no double brace (Renovate compiles the command as a template).
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
const dir = ".github/workflows";
const pin = /^ +uses: ([\w.-]+\/[\w.-]+)\/\.github\/workflows\/[\w.-]+@([0-9a-f]{40}) # (v\d+\.\d+\.\d+)$/m;
let found = null;
for (const name of readdirSync(dir).filter((n) => /^kskill-[\w.-]+\.ya?ml$/.test(n)).sort()) {
  found = readFileSync(join(dir, name), "utf8").match(pin);
  if (found) break;
}
if (!found) { console.error("No caller pinned by a commit: nothing to regenerate."); process.exit(1); }
const [, self, sha, version] = found;
const home = mkdtempSync(join(tmpdir(), "kskill-callers-"));
for (const file of ["scripts/kskill-callers.mjs", ".github/callers.json"]) {
  const res = await fetch(`https://raw.githubusercontent.com/${self}/${sha}/${file}`);
  if (!res.ok) { console.error(`${file} at ${sha}: HTTP ${res.status}`); process.exit(1); }
  mkdirSync(dirname(join(home, file)), { recursive: true });
  writeFileSync(join(home, file), await res.text());
}
execFileSync(process.execPath, [join(home, "scripts/kskill-callers.mjs"), "write", "--self", self, "--sha", sha, "--version", version], { stdio: "inherit" });
