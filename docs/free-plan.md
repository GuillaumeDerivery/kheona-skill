<!-- This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
     not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/. -->

# Built for the free plan

- Workflows are shared from a public repository, which a private repository on any plan may call.
- No required reviewers or protected tags on private repositories: a deploy checks that its tag is on `main`, and production trusts version tags through OIDC.
- No secret needs an organization: every value is a repository variable or secret, passed by name.
- The token broker fits a free Cloudflare Worker.
