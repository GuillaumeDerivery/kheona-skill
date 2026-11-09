<!-- This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
     not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/. -->

# Kheona stack extension — Terraform / infra

Covers an infrastructure repository (Terraform, Kubernetes manifests, a CDN and DNS). K4 reads differently here — see
below.

## K1 — Toolchain

```bash
terraform version
grep -rn "required_version\|required_providers" --include="*.tf" . | head -20
git ls-files --error-unmatch .terraform.lock.hcl     # K1.2 — the provider lock MUST be committed
grep -n "terraform_version" .github/workflows/*.yml  # K1.1
```

Every provider needs a pinned `version` constraint **and** a committed `.terraform.lock.hcl`. An
unpinned provider means `terraform init` on a fresh runner can produce a different plan than yours —
which, on infra, means an unreviewed change to live resources.

## role: infra — what the automation does for it

One infra repository per GitHub owner (`owner/infra`: Terraform under `terraform/`, Kubernetes manifests under
`eks/<namespace>/`, secrets under git-crypt) takes `.kheona.json` `"role": "infra"`. Applying is manual (`terraform apply`,
`kubectl apply`), so nothing about it merges or applies itself; the automation says **when** to act. Its callers are
`kskill-pr.yml` and `kskill-ci.yml` (calling `kskill-ci-infra.yml`), nothing else: no `kskill-main.yml`, deploy or inbox.

- **Renovate** ([../renovate/infra.json](../renovate/infra.json), which `renovate.json` extends at the callers' version).
  Third-party images in `eks/**/*.ya?ml`, Terraform providers and modules: minor/patch in the weekly PR, majors as the
  draft; nothing auto-merges. The apps' own images (a commit SHA tag or digest written by their deploys) are left alone.
  cert-manager and ingress-nginx are applied from their release manifests: a regex manager follows each one's GitHub
  release through its `app.kubernetes.io/version` labels, in a draft of its own that says to replace the file with the
  release's. `backup/` and other copies are not applied, so not updated. **Declare every provider in
  `required_providers` with a constraint** (`aws = { source = "hashicorp/aws", version = "~> 5.56" }`): without one,
  Renovate has nothing to bump and its lock file PR may move a major.
- **End of support** (K1.5), checked on a schedule, not by Renovate: the EKS version against endoflife.date (warn 90
  days before standard support ends: extended support bills the control plane 6×; the cluster's upgrade policy says
  whether that date upgrades it or starts the bill), cert-manager's release, ingress-nginx (archived upstream: replace
  it), the Terraform AWS provider's major (only the latest gets fixes). **The EKS add-ons running in the cluster**
  (vpc-cni, CoreDNS, kube-proxy, the CSI drivers, the Pod Identity agent, managed or the self-managed copies EKS
  installed at creation, which nothing upgrades) against what EKS publishes for the cluster's version and the next one:
  an add-on not compatible with the next version blocks the upgrade. One issue per component, with the steps. Better
  still, declare the add-ons as `aws_eks_addon` resources so the repository says what runs.
  ```bash
  curl -s https://endoflife.date/api/amazon-eks.json | jq -r '.[0:4][] | "\(.cycle) support=\(.support) eol=\(.eol)"'
  aws eks describe-addon-versions --kubernetes-version <next> --addon-name <addon> --query 'addons[].addonVersions[0].addonVersion'
  ```

## Posture audit — the live account and cluster (K5.8)

What a per-commit check cannot see: how the account and the cluster are actually configured. Run every check below
monthly, read-only, with the repository's AWS profile and region, and keep the result in one issue per repository
(`Infra audit: …`, refreshed in place, one box per gap). Each is one command; run it to verify a box before ticking it. `<account>` is `aws sts get-caller-identity --query Account --output text`.

**Account baseline**
```bash
aws cloudtrail describe-trails            # a trail with IsMultiRegionTrail and LogFileValidationEnabled ...
aws cloudtrail get-trail-status --name <trail-arn>   # ... and IsLogging
aws guardduty list-detectors              # a detector; get-detector --detector-id <id>: Status ENABLED
aws accessanalyzer list-analyzers         # an ACTIVE analyzer of type ACCOUNT (or ORGANIZATION)
aws securityhub describe-hub; aws configservice describe-configuration-recorders
                                          # both on, or the decision not to recorded in CLAUDE.md (a line naming Security Hub)
aws ec2 get-ebs-encryption-by-default     # EbsEncryptionByDefault: true
aws s3control get-public-access-block --account-id <account>
                                          # all four flags; a bucket public on purpose through its policy is allowed
                                          # when BlockPublicAcls and IgnorePublicAcls are on (ACLs never make one public)
```

**IAM** (the credential report: `generate-credential-report` builds it and changes nothing)
```bash
aws iam generate-credential-report >/dev/null; aws iam get-credential-report --query Content --output text | base64 -d
#   password_enabled true (or the root user) with mfa_active false        → a console user without MFA
#   access_key_N_active true, last_rotated > 90 days or last_used_date N/A → an old or never-used key
aws iam list-open-id-connect-providers    # token.actions.githubusercontent.com; a CI-named user (github, ci, deploy...)
                                          # with an active key is CI on static keys instead of OIDC
```

**Network**
```bash
aws ec2 describe-security-groups          # no 0.0.0.0/0 or ::/0 ingress except tcp 80/443 (load balancers)
aws ec2 describe-network-interfaces       # every group but `default` is on an ENI (else: unattached, delete it)
aws ec2 describe-instances --query 'Reservations[].Instances[].[InstanceId,MetadataOptions.HttpTokens]'   # all required (IMDSv2)
```

**EKS**
```bash
aws eks describe-cluster --name <cluster> --query 'cluster.[logging.clusterLogging,resourcesVpcConfig.publicAccessCidrs,accessConfig.authenticationMode]'
#   audit and authenticator enabled; publicAccessCidrs not 0.0.0.0/0 (or the endpoint private); authenticationMode not CONFIG_MAP
```

**Workloads**, from the repository's `eks/**/*.y*ml` (not `backup/` or `old-*`; git-crypt files skipped): every container of a
Deployment, StatefulSet, DaemonSet or CronJob sets `resources.requests` and `resources.limits.memory`; each has a pod or
container `securityContext`; every namespace with workloads has a `NetworkPolicy`; every Deployment or StatefulSet with more
than one replica is selected by a `PodDisruptionBudget`; each has a liveness or readiness probe. And metrics-server runs:
```bash
kubectl get deployments -A | grep metrics-server; aws eks list-addons --cluster-name <cluster>
```

**ECR**
```bash
aws ecr get-registry-scanning-configuration   # a SCAN_ON_PUSH (or CONTINUOUS_SCAN) rule on `*`, or ENHANCED ...
aws ecr describe-repositories --query 'repositories[].[repositoryName,imageScanningConfiguration.scanOnPush]'   # ... or every repository on push
```
Tag immutability is deliberately **not** required: the shared deploy deploys by digest (SKILL.md K2.9), and a re-run
rebuilds the same commit under the same SHA tag.

**Operations**
```bash
ls .github/workflows/kskill-ci.yml        # the infra CI (K2.1 below)
aws cloudwatch describe-alarms            # at least one; each with an AlarmActions target; an AWS/ApplicationELB 5XX alarm
aws elbv2 describe-load-balancers         #   wherever an application load balancer runs
aws dlm get-lifecycle-policies; aws backup list-backup-plans   # an ENABLED DLM policy or a Backup plan
```

## K2 — Pipeline

- **K2.1** The gate is the shared `kskill-ci-infra.yml`, called from the repository's `.github/workflows/kskill-ci.yml`
  by `kskill-pr.yml` on every PR: the repository check and secret scan, `terraform fmt -check -recursive`,
  `init -backend=false` + `validate` per root, `tflint --recursive`, `trivy config` (HIGH and CRITICAL fail,
  `.trivyignore` honoured) and `kubeconform -strict` over `eks/`. The Terraform version comes from `.terraform-version`
  or an exact `required_version` (K1.1). git-crypt files are ciphertext in CI: an encrypted `.tf` is emptied and the
  variables it declared are stubbed for `validate`, so keep only `variable` blocks in encrypted Terraform; encrypted
  YAML is skipped. **No `terraform plan` in CI**: it needs the cloud credentials and the state; Terraform Cloud's
  VCS-driven speculative plan is the plan on the PR.
- **K2.2 / K2.8** `terraform apply` is a person's act on reviewed code (or Terraform Cloud's, after a person confirms
  the plan), never from a PR, never from a fork, never on every merge without a reviewed plan. Applying on merge makes
  "merged" and "changed in the cloud account" the same event, with nothing between the reviewed plan and the apply.
- **K2.3** State backend is remote, versioned and locked. You can name where state lives, who can read
  it (it contains secrets in plaintext), and how to recover a previous version.
- **K2.4** `permissions: contents: read`; the shared gate writes nothing.

**K1.5 — is the pinned Terraform still current?**
```bash
terraform version                       # prints "your version is out of date" when it is
curl -s https://endoflife.date/api/terraform.json | jq -r '.[0:4][] | "\(.cycle) eol=\(.eol)"'
```
Provider majors matter as much as the CLI: a provider two majors behind usually cannot express newer
resource arguments at all, which is how "we can't enable that" quietly becomes an architecture decision.

## K3 — Code health

```bash
terraform fmt -recursive -check
terraform validate
tflint --recursive
tfsec . || trivy config .
grep -rn "hardcoded\|0.0.0.0/0" --include="*.tf" .   # K3.6 — each one justified in a comment
terraform plan -detailed-exitcode                     # exit 0 = no drift; 2 = drift
git status --short
```

**K3.3–K3.5 (design system) are N/A here** — this stack renders no UI. State that in the audit; an
unstated N/A reads the same as an unexamined item.

**Drift is the real K3 check here.** A clean `plan` against live infrastructure is the statement that the
code describes reality. Anything changed by hand in a console is a FAIL with a note, not a shrug.

## K4 — Tests (the ≥ 90 % line coverage rule does not transfer)

There is no meaningful line coverage for HCL. The equivalent bar:
- **K4.1** `terraform validate` + `tflint` + a policy check (`tfsec` / OPA / Sentinel) all pass.
- **K4.2** Every module has at least one `examples/` directory that plans cleanly.
- **K4.3** All of the above run as a required check on the protected branch.
- **K4.5** Assertions on the things that are expensive when wrong: no public S3/bucket ACLs, no
  `0.0.0.0/0` ingress on anything but a load balancer, encryption at rest on every store, deletion
  protection on stateful resources, and a tag policy that makes cost attributable.

Record in the audit that K4.2's percentage is **N/A for this stack**, with this substitution named —
don't silently drop the section.

## K5 — Secrets

```bash
git log --all --oneline -S"BEGIN PRIVATE KEY" | head
grep -rnE "password|secret|token|access_key" --include="*.tf" --include="*.tfvars" . | grep -v "var\.\|data\."
git ls-files | grep -E "\.tfvars$|\.tfstate"     # neither belongs in git
```

**git-crypt covers every secret file** (SKILL.md K5.1). An infra repository that
encrypts its Kubernetes Secrets with git-crypt keeps a `.gitattributes` rule over **every** secret file: `.yml` as well
as `.yaml` (a `*secret.yaml` rule leaves `x-secret.yml` in plaintext), and in every directory, `old-*/` and `backup/`
copies included (a moved file keeps its rule only if its new directory has one). A secret file is a tracked file under a
`secrets/` directory, whose name contains `secret` and ends in `.yaml`/`.yml`, or ends in `.secret` (case-insensitive),
or any YAML file holding a `kind: Secret` document (a cert-manager issuer's API token, say). A rule added after a
file was committed does not encrypt it: `git rm --cached` and `git add` it again (unlocked), and rotate every value it
held, since the plaintext stays in the history. The repository check (check 8) enforces both halves in CI, without
the key: the filter attribute, and the stored blob's `\0GITCRYPT\0` header. It prints paths, never contents.
**Backups and archives** (`backup/`, `old-infra/`...) are not git-crypted: every secret
value in them is replaced by the literal `GITLEAKS_SECRET_REPLACED` instead. Check 8 accepts such a file: a plaintext
`kind: Secret` manifest whose every top-level `data`/`stringData` value is the placeholder or empty holds no value. Any
other value (a block scalar, a nested or flow value, a `kind: List`) keeps it a finding.

```bash
f=eks/app/secrets/app-secret.yml
git check-attr filter -- "$f"                                   # filter: git-crypt
git cat-file blob ":$f" | head -c 10 | od -An -c                # \0 G I T C R Y P T \0
git grep --cached -lE '^kind:[[:space:]]*Secret[[:space:]]*$' -- '*.yaml' '*.yml'   # must print nothing: a match is a plaintext Secret
```


**K5.6 — the real client IP** (load balancer in front of services): the ALB admits only the CDN's ranges
(Cloudflare's IPv4 list in `IngressClassParams` `inboundCIDRs`, or the security group), so `X-Forwarded-For` cannot be
forged by calling the origin directly; and its access logs are on, to an S3 bucket with a delivery policy and an
expiry (`access_logs.s3.*` in `loadBalancerAttributes`; the bucket in Terraform, applied first). Those logs hold the
CDN edge's address and no headers, so the device's IP comes from a **WAF web ACL** on the ALB: no rules, default allow,
`aws_wafv2_web_acl_logging_configuration` to an `aws-waf-logs-*` bucket with `Authorization` and `Cookie` redacted,
attached by `IngressClassParams` `wafv2AclArn` (in an infra repository: `terraform/alb-logs.tf`,
`terraform/waf-logs.tf` and `eks/aws-load-balancer-controller/ingressclass.yaml`).

## Domains — DNS in code, strict email security (K5.9)

Every record of every zone is a Terraform resource (Cloudflare: `cloudflare_dns_record`, one comment naming the file on
each; the records Cloudflare owns itself, Worker custom domains, R2 and Email Routing, through those resources). The
email-security records of SKILL.md K5.9 are resources like any other, never dashboard edits. Check each zone:

```bash
d=example.com
dig +short MX $d                         # mail domain: the real MX; no-mail domain: exactly "0 ."
dig +short TXT $d | grep spf1            # exactly one, ends "-all"
dig +short TXT _dmarc.$d                 # p=reject; sp=reject; adkim=s; aspf=s (pct absent or 100)
dig +short TXT <selector>._domainkey.$d | tr -d '" ' | sed 's/.*p=//' | base64 -d \
  | openssl pkey -pubin -inform DER -noout -text | head -1       # per sender: RSA Public-Key: (2048 bit) or more
dig +short TXT _mta-sts.$d; curl -s https://mta-sts.$d/.well-known/mta-sts.txt   # with an MX: v=STSv1, mode: enforce
dig +short TXT _smtp._tls.$d             # with an MX: v=TLSRPTv1; rua=…
dig +short DS $d                         # non-empty: DNSSEC chain published at the registrar
dig +short TXT $d._report._dmarc.<rua-domain>   # when rua is at another domain: v=DMARC1
```

A no-mail domain also carries `*._domainkey` TXT `v=DKIM1; p=`. The DS record lives at the registrar, often outside the
IaC: record where it is set in the repository's `CLAUDE.md`. In Terraform the records sit in one file (`terraform/dns.tf`),
one `cloudflare_dns_record` per record, a no-mail zone's five records together as the template for the next one.

## K6 / K7 — no stack-specific commands

Review and tracker hygiene (K6) and documentation currency (K7) are identical for every stack. Apply
`SKILL.md`'s criteria directly — `gh pr list`, `gh issue list`, `git log --oneline origin/main..HEAD`, a
code-review pass on the branch, and a read of the repo's own `CLAUDE.md`/README against the code as it
is now. K6.3 has one command everywhere: `/code-review` on the full branch. **None of this is optional here just because this file carries no stack-specific commands for it.**

## K8 — Release readiness

- **K8.1** Resource naming and tagging follow one convention across every module.
- **K8.2** Rollback = revert the commit and re-apply, **or** a named manual procedure for resources where
  that is destructive (databases, DNS cutovers). Write which one it is per module; "revert and apply" is
  a dangerous default for stateful infra.
- **K8.4** Alarms exist on the things that page someone, and route somewhere a human reads.
