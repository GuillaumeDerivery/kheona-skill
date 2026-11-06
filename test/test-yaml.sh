#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# Every workflow and action must be valid YAML: an action only loads when a job reaches it, and a pull request skips
# the deploy job, so a broken action would otherwise surface on the first real deploy.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd); cd "$HERE" || exit 64
ruby -ryaml -e '
pass = failed = 0
Dir[".github/{workflows,actions/*}/*.{yml,yaml}"].sort.each do |f|
  begin
    raise "not a mapping" unless YAML.parse_file(f).to_ruby.is_a?(Hash)
    pass += 1; puts "ok   #{f}"
  rescue StandardError, Psych::SyntaxError => e
    failed += 1; puts "FAIL #{f}: #{e.message}"
  end
end
puts "#{pass} passed, #{failed} failed"
exit(failed.zero? && pass.positive? ? 0 : 1)'
