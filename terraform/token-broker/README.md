<!-- This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
     not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/. -->

# Token broker

A Cloudflare Worker (free plan) that swaps a GitHub Actions OIDC identity for a short-lived GitHub App token. No App key in any repository.

```hcl
module "token_broker" {
  source     = "github.com/owner/kheona-skill//terraform/token-broker?ref=<sha>" # v1.x.y
  account_id = var.account_id
  app_id     = "123456"
  hostname   = "broker.example.com"
  zone_id    = var.zone_id
  policy = {
    workflowRepositories = ["owner/kheona-skill"]
    owners               = ["owner"]
    audience             = "kskill-token-broker"
    maxPermissions       = { contents = "write", pull_requests = "write", issues = "write", actions = "write", checks = "read", workflows = "write" }
    shared               = { owner = ["owner/library"] }
    acrossOwners         = ["owner/runner"]
  }
}
```

Leave `hostname` empty unless the zone lets GitHub's runners through. Many zones show datacenter traffic a bot challenge: the request ends in a 403 the Worker never sees. The workers.dev address has no such rules.

Then store the key, converted to PKCS#8, once:

```bash
openssl pkcs8 -topk8 -nocrypt -in app.pem | npx wrangler secret put KSKILL_APP_PRIVATE_KEY --name kskill-token-broker
```

Tests: `node --test terraform/token-broker/worker/test/*.test.mjs`.
