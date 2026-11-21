<!-- This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was
     not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/. -->

# Kheona stack extension — static web / Cloudflare Workers

Covers static sites (hand-written HTML/CSS/JS, no build step, Cloudflare Workers Static
Assets) and any similar marketing or docs site.

## K1 — Toolchain

```bash
cat wrangler.toml wrangler.jsonc 2>/dev/null       # compatibility_date pinned, not floating
grep -n "compatibility_date" wrangler.*
ls package.json 2>/dev/null                         # if none: "no build step" is the pin, state it
cat renovate.json                                   # extends the preset (github-actions at minimum)
```

A no-build site still has a toolchain: the Workers runtime. `compatibility_date` **is** the pin — an
absent or very old one is a K1.1 finding.

## K2 — Pipeline

```bash
grep -nE "runs-on|needs:|if:|timeout-minutes|permissions" .github/workflows/*.yml
gh secret list                                      # CLOUDFLARE_API_TOKEN scope = Workers edit only
```
Production deploys from a version tag only (K2.2, K2.8) — never on a merge to `main`, which may deploy a
preview or staging. The cost and version-number halves of K2.8's rationale are weak here (an edge deploy is
cheap and idempotent, and nothing finite is consumed), but the third half is not: without a release step, merged
means live, and the site has no staging step at all. A site deployed by the edge's own Git integration is configured
there to build production from tags, or deployed by the repository's own workflow (`workflows.cd.target: "custom"`)
after the shared release check. K2.3: the Cloudflare API token's scope and its owning
account are the inventory item — a global-key token in CI is a finding.

**K2.7 — published to the edge that serves it.**
```bash
grep -nE "wrangler|cloudflare/wrangler-action|pages deploy|aws s3 sync|cloudfront" .github/workflows/*.yml
gh release list --limit 5                                            # the last production releases
curl -sI https://<domain>/ | grep -iE "cf-ray|server|last-modified"   # is the live site the last deploy?
```
**Pass:** the production deploy runs from a version tag, reaches the CDN/edge that actually
serves the domain (Cloudflare Workers/Pages here, CloudFront elsewhere), and — where the platform caches
independently of the zone — the cache behaviour ships **with** the deploy (the `_headers` file), not as a
dashboard rule someone set once. Verify the live site reflects the most recent run rather than assuming.

## K3 — Code health

```bash
npx html-validate "**/*.html"
npx stylelint "css/**/*.css"
npx eslint js/                                       # even without a bundler
grep -rn "http://" --include="*.html" --include="*.js" . | grep -v localhost
grep -rniE "TODO|FIXME|lorem ipsum" --include="*.html" .
git status --short                                   # K3.8
```

**K3.3 — the design system exists.** On a site with no build step the design system *is* the custom
property block plus a documented set of component classes. Both halves:
```bash
grep -n -A40 ":root" css/*.css | head -60     # tokens: colour, type scale, spacing, radius, shadow
grep -rn "^\.[a-z-]*\s*{" css/components*.css 2>/dev/null | head -30   # or this site's component layer
```
**Pass:** a token exists for each category, and repeated UI (button, card, nav item, form field) is a
named class using those tokens — not a fresh rule set written next to each section of each page.

**K3.4/K3.5 — reuse, and register what is new.** A new pattern becomes a component class in the shared
stylesheet, used by name from the page; it does not become a page-specific rule block. What is new is
listed wherever the site documents its classes, and in the repo's `CLAUDE.md`.

**K3.6 — invariants.** A hand-written site drifts fastest. Every colour, font size and spacing value
should come from a CSS custom property:
```bash
grep -rnE "#[0-9a-fA-F]{3,8}\b" css/ | grep -v ":root"     # literal colours outside the token block
grep -rn "style=\"" --include="*.html" .                     # inline styles bypass the system
grep -rnE "font-size:\s*[0-9]" css/ | grep -v ":root"      # type scale bypassed
```

## K4 — Tests (line coverage does not transfer)

Substitute, and say so in the audit rather than dropping the section:
- **K4.1** Link check: no internal 404s, no broken assets.
- **K4.2** Lighthouse CI on the built site with budgets asserted — performance, accessibility, SEO and
  best-practices thresholds, failing the run when a budget regresses.
- **K4.3** Both run as a required check on the protected branch.
- **K4.5** What actually costs money when wrong: the analytics/consent script loading, the contact form
  submitting, every legal-document link resolving, and `<title>`/`<meta description>`/OG tags present on
  every page (the full list: K4.6).

```bash
npx linkinator ./ --recurse --skip "^https?://(?!localhost)"
npx @lhci/cli autorun
```

## K4.6 — Public face (a public marketing site)

What search engines, link previews, browsers and stores read before anyone sees the page. Each item is one
command against the **live** domain; run them on every page that is meant to be indexed.

```bash
D=https://<domain>
page() { curl -fsS "$D$1"; }
# Head tags of each indexable page
page / | grep -oE '<title[^>]*>[^<]*|name="description"[^>]*|rel="canonical"[^>]*|<html[^>]*lang="[^"]*"|property="og:[a-z:_]*"|name="twitter:[a-z]*"' 
page / | grep -c '<h1'                                                # exactly 1
# Icons and app metadata, at the paths clients ask for without reading the page
for p in /favicon.ico /apple-touch-icon.png /site.webmanifest /robots.txt /sitemap.xml; do
  echo "$p $(curl -s -o /dev/null -w '%{http_code} %{content_type}' $D$p)"; done
# One canonical host, HTTPS only
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' http://<domain>/        # 301 to https
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' https://www.<domain>/   # 301 to the canonical host
curl -s -o /dev/null -w '%{http_code}\n' $D/no-such-page                         # 404, not 200
curl -sI $D/ | grep -iE 'strict-transport|content-security|x-content-type|referrer-policy|permissions-policy'
npx lighthouse@12 $D/ --quiet --chrome-flags=--headless=new \
  --only-categories=performance,accessibility,best-practices,seo --output=json --output-path=lh.json
```

**Pass**, every one of these:
- **Title and description**: a unique `<title>` of at most 60 characters and a `<meta name="description">` of 70 to
  160 per page; longer ones are cut in results. `<html lang>` set; one `<h1>`.
- **Canonical**: an absolute `rel="canonical"` on every indexable page, naming the canonical host.
- **Link previews**: `og:title`, `og:description`, `og:url`, `og:type`, `og:image` (an absolute URL to a
  **1200×630** image made for sharing, not the app icon) with `og:image:width`, `og:image:height` and
  `og:image:alt`; `twitter:card` = `summary_large_image`. Check one with a preview debugger before launch.
- **Icons**: `/favicon.ico` answers 200 at the root (crawlers and some browsers ask for it without reading the page),
  plus an SVG and a 48 px PNG icon linked from the page; `/apple-touch-icon.png` (180×180, opaque) at the root;
  `site.webmanifest` with 192 and 512 px icons, one of them `"purpose": "maskable"`.
- **Crawl files**: `robots.txt` names the sitemap; `sitemap.xml` lists every indexable page with `<lastmod>`; the
  404 page answers **404** and carries `noindex`; legal pages are in the sitemap.
- **One host**: `http://` redirects 301 to `https://`; the other of `www`/apex redirects 301 to the canonical host
  (a second host answering 200 is duplicate content); HSTS on.
- **Languages**: each language has its own URL (`/en/`), linked with `hreflang` alternates and an `x-default`.
  A language switched only in JavaScript on one URL is never indexed: either give it URLs or say the site is
  single-language for search.
- **Structured data**: JSON-LD for the organisation and, for an app's site, `MobileApplication` (name, operating
  systems, category, publisher, the store URLs once public); valid in a rich-results test.
- **Search engines**: the domain is verified in the search consoles that matter (a DNS TXT record, managed where
  the zone's DNS is managed, not by hand) and the sitemap is submitted.
- **Lighthouse**: each of the four categories at 90 or more on mobile; the remaining findings listed in the audit
  (images sized and in a modern format, versioned assets cached long, links not told apart by colour alone,
  valid ARIA roles).
- **Legal**: a legal notice and a privacy policy, both linked from every page's footer. A store listing requires the
  privacy policy URL, so an app's site is not ready to back a submission without it.

## K5 — Privacy

```bash
grep -rniE "analytics|gtag|hotjar|facebook|pixel" --include="*.html" --include="*.js" .
```
Every third-party script is a GDPR answer you must defend, and a consent banner that loads it before
consent is a real exposure — not a cosmetic one.


## K6 / K7 — no stack-specific commands

Review and tracker hygiene (K6) and documentation currency (K7) are identical for every stack. Apply
`SKILL.md`'s criteria directly — `gh pr list`, `gh issue list`, `git log --oneline origin/main..HEAD`, a
code-review pass on the branch, and a read of the repo's own `CLAUDE.md`/README against the code as it
is now. K6.3 has one command everywhere: `/code-review` on the full branch. **None of this is optional here just because this file carries no stack-specific commands for it.**

## K8 — Release readiness

```bash
curl -sI https://<domain>/ | grep -iE "cache-control|cf-cache-status|content-security-policy"
cat _headers
curl -fsS https://<domain>/ -o /dev/null && echo up      # K8.3
```

**Workers Static Assets caching trap:** on a domain served by Workers Static Assets (a Worker bound as a
Custom Domain), **zone-level Cloudflare Cache Rules and Page Rules have no effect** — Workers Static
Assets has its own caching layer, controlled only by the repo's `_headers` file. Before assuming a
dashboard cache rule will take effect on any Cloudflare-fronted property, check whether it is a plain
proxied origin or a Worker/Pages app.

**K8.2** rollback = redeploy the previous commit, or `wrangler rollback`. Confirm which one the account
actually supports before writing it down.
