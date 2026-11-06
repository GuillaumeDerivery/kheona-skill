# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
# not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
# The App key is never here, so it never reaches the state: set it once from outside and every apply keeps it
# (`keep_bindings`):  npx wrangler secret put KSKILL_APP_PRIVATE_KEY --name <script_name>
resource "cloudflare_workers_script" "broker" {
  account_id         = var.account_id
  script_name        = var.script_name
  main_module        = "index.mjs"
  compatibility_date = "2026-10-01"
  content            = file("${path.module}/worker/index.mjs")
  keep_bindings      = ["secret_text"]

  bindings = [
    { type = "plain_text", name = "POLICY", text = jsonencode(var.policy) },
    { type = "plain_text", name = "KSKILL_APP_ID", text = var.app_id },
  ]
}

resource "cloudflare_workers_custom_domain" "broker" {
  count      = var.hostname == "" ? 0 : 1
  account_id = var.account_id
  zone_id    = var.zone_id
  hostname   = var.hostname
  service    = cloudflare_workers_script.broker.script_name
}
