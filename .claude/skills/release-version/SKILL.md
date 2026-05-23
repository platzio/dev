---
name: release-version
description: |
  Cut a new Platzio release. Use when the user says any of: "release a
  version", "publish a release", "cut a release", "release v0.x.y",
  "release a beta", "release v...-beta...". Coordinates tagging the
  backend / frontend / base-image, bumping the helm chart, updating the
  Terraform module, and writing a release blog post. Asks the user
  whether the release is beta or stable before doing anything.
---

# Release a Platzio version

Cutting a Platzio release touches **five repos** in a specific order. Each
step has wait points where you're blocked on an upstream CI run; do
**not** proceed past a wait point until the build completes.

Sibling repos used here, relative to `dev/`:

- `../backend` — Rust workspace.
- `../frontend` — Vue SPA.
- `../base-image` — Alpine base used by the helm pod. Rarely bumps.
- `../sdk-rs` — Rust SDK published to crates.io as `platz-sdk`.
- `../sdk-js` — TypeScript SDK published to npm as `@platzio/sdk`.
  Auto-generated from the backend's OpenAPI schema.
- `../helm-charts` — the `platzio` chart.
- `../terraform-aws-platzio` — Terraform module.
- `../site` — public docs + blog (PR-only; see [[feedback-site-pr-only]]).

## Phase 0 — Ask the user

Before doing anything else, ask **two** questions via `AskUserQuestion`:

1. **Release type.** Beta (`vX.Y.Z-beta.N`) or stable (`vX.Y.Z`)?
2. **Version number.** Suggest the next number based on existing tags
   (`git -C ../backend tag --sort=-creatordate | head -5`) but let the
   user confirm. Don't assume.

If the user asks for a stable bump but there's no preceding beta, that's
usually fine but worth flagging — most stable releases historically
followed one or more betas.

## Phase 1 — Check what changed in each repo

For each of `../backend`, `../frontend`, `../base-image`, `../sdk-rs`,
`../sdk-js`, run:

```bash
cd ../<repo>
git fetch origin --tags
LAST_TAG=$(git tag --sort=-creatordate | head -1)
git log "${LAST_TAG}..origin/main" --oneline
```

- **If commits are listed** → this repo needs a new release. Note it.
- **If no commits** → this repo is unchanged; reuse the existing latest
  tag (or version) in everything downstream. Don't tag a no-op release.

`base-image` uses a non-semver scheme (`v1`, `v2`, …, `v8`). Bump it
only if its source actually changed.

`sdk-js` doesn't keep git tags — it tracks `package.json` `version`. To
decide whether it needs a release, compare the current `package.json`
`version` to the backend version it was last generated against and to
the OpenAPI schema in the backend release: if the backend's OpenAPI
surface changed and you want consumers to see it, bump `sdk-js`. The
default is to release `sdk-js` whenever the backend is released —
re-generation is cheap and avoids consumers drifting from the API.

`sdk-rs` is a hand-maintained Rust crate. Release whenever:

- there are commits on `../sdk-rs/main` since its last `v...` tag, **or**
- the backend's API surface changed (new collection, new endpoint, new
  fields on existing structs) and the SDK hasn't been re-synced yet —
  Phase 3a covers the sync work.

In practice this means: release sdk-rs almost every time the backend
is released. The exception is releases that touched no API surface
(internal-only changes to k8s-agent, chart-discovery, resource-sync,
etc.) — in that case sdk-rs can sit out.

Save the result as a small table you'll refer to throughout the rest of
the workflow:

| Repo       | Old tag / version | New tag / version | Notes                  |
| ---------- | ----------------- | ----------------- | ---------------------- |
| backend    | v0.6.8            | v0.6.9            | (or "unchanged")       |
| frontend   | v0.6.0            | v0.6.0            | (unchanged — reuse)    |
| base-image | v8                | v8                | (unchanged — reuse)    |
| sdk-rs     | v0.6.3            | v0.6.4            | (hand-maintained)      |
| sdk-js     | 0.6.1             | 0.6.9             | (matches backend ver.) |

## Phase 2 — Tag and push backend / frontend / base-image

For each repo that has changes:

```bash
cd ../<repo>
git checkout main
git pull origin main
git tag "${NEW_TAG}"
git push origin "${NEW_TAG}"
```

The tag push triggers a GitHub Actions release workflow (`v**` tag
filter). Watch it complete before moving on:

```bash
gh -R platzio/<repo> run list --branch "${NEW_TAG}" --limit 1
gh -R platzio/<repo> run watch <run-id>
```

⚠️ **Wait point.** Do not proceed until the workflow finishes
successfully — the helm chart's image references won't exist on Docker
Hub yet otherwise. Backend's multi-arch build takes ~20 minutes on
native runners; frontend ~5 minutes; base-image ~2 minutes.

If the workflow fails, fix the underlying issue, delete the tag locally
*and* on origin (`git push --delete origin <tag>`), re-tag, push again.

## Phase 3 — Release the SDKs

The SDKs publish to public package registries. They must be released
**after** Phase 2 (specifically, after the backend's release CI
finishes), because `sdk-js` downloads `openapi.yaml` from the backend's
GitHub release as part of its own build.

### 3a. sdk-rs (`platz-sdk` on crates.io)

By convention sdk-rs's version tracks backend so they read together in
release notes. Match the new backend version unless there's a reason
not to.

Unlike sdk-js, sdk-rs is **hand-maintained**. There's no codegen step
from OpenAPI. That means each release is also a maintenance pass to
keep the SDK aligned with the backend's API surface — otherwise the
SDK drifts and consumers can't reach newer collections.

#### Step 1: Sync the SDK to the backend's API collections

This is the most important part of releasing sdk-rs, and the easiest
to forget.

1. **Enumerate API collections.** Every file in
   `../backend/api/src/routes/v2/` represents one API collection,
   except `mod.rs`, `server.rs`, and `auth.rs`.

   ```bash
   ls ../backend/api/src/routes/v2/*.rs \
     | xargs -n1 basename | grep -vE '^(mod|server|auth)\.rs$' | sort
   ```

2. **Enumerate SDK resources.**

   ```bash
   ls ../sdk-rs/src/resources/*.rs \
     | xargs -n1 basename | grep -v '^mod\.rs$' | sort
   ```

3. **Diff the two lists.** Anything in the backend list but not in the
   SDK list is a missing collection. Common offenders historically:
   `bots`, `bot_tokens`, `deployment_permissions`,
   `env_user_permissions`, `helm_tag_formats`. Confirm with the user
   whether each missing collection should be added — sometimes
   intentional (e.g., a backend-internal collection that doesn't make
   sense in client code), more often a drift that should be fixed.

4. **For each collection that needs adding:**

   - Read the backend's route file (`../backend/api/src/routes/v2/<col>.rs`)
     and the corresponding schema (`../backend/db/src/schema/<col>.rs`)
     to understand the endpoints and the struct shapes.
   - Add a new file `../sdk-rs/src/resources/<col>.rs` mirroring the
     pattern in existing resources (e.g.
     [`users.rs`](../../sdk-rs/src/resources/users.rs) is a good
     template): one `Deserialize` struct per resource, a `Filter`
     struct for list queries, optional `Update*` / `New*` structs for
     mutations, plus `impl PlatzClient` methods covering the list,
     get, create, update, and delete endpoints the backend exposes.
   - Update `../sdk-rs/src/resources/mod.rs` to `mod <col>;` and
     `pub use <col>::*;`.

5. **For collections that already exist in the SDK**, scan the diff in
   the backend's schema since the SDK's last tag:

   ```bash
   cd ../backend
   LAST_SDK_TAG=$(cd ../sdk-rs && git tag --sort=-creatordate | head -1)
   # find when that tag was created, then diff schemas since then
   SDK_TAG_DATE=$(cd ../sdk-rs && git log -1 --format=%ai "$LAST_SDK_TAG")
   git log --since="$SDK_TAG_DATE" --oneline -- db/src/schema/ api/src/routes/v2/
   ```

   For each commit touching a schema file, check whether the
   corresponding SDK struct needs the same change (new field, type
   change, new endpoint). Most field additions in the backend should
   propagate to the SDK as new `Option<T>` fields (so older SDK
   versions still parse newer backend responses gracefully).

6. **Run `cargo check`** to make sure everything compiles. If you
   added new types that the backend uses but the SDK didn't reference,
   pull them in via additional `Deserialize` structs.

#### Step 2: Bump version and publish

Once the sync is complete (or there was nothing to sync):

```bash
cd ../sdk-rs
git checkout main && git pull origin main
# edit Cargo.toml → version = "<NEW_VERSION_NO_V>"
cargo check                       # refreshes Cargo.lock
git add Cargo.toml Cargo.lock src/ # if you also added resources
git commit -m "v<NEW_VERSION>"
git tag "v<NEW_VERSION>"
git push origin main
git push origin "v<NEW_VERSION>"
```

The tag push triggers `.github/workflows/release.yml` which runs
`cargo clippy && cargo build` and publishes via
`katyo/publish-crates`.

```bash
gh -R platzio/sdk-rs run watch <run-id>
```

⚠️ **Wait point.** crates.io publishes are irrevocable — a yanked
version can't be re-published. If clippy or build fails, the publish
step doesn't run; fix the code and re-tag (delete the old tag first).

Verify the new version appears at
<https://crates.io/crates/platz-sdk>.

### 3b. sdk-js (`@platzio/sdk` on npm)

`sdk-js` is **always** released right after backend, because the npm
SDK is auto-generated from the backend's OpenAPI schema. Consumers
expect the npm version to match the backend version they're targeting.

1. Bump `package.json` to **the new backend version** (no leading `v`):

   ```bash
   cd ../sdk-js
   git checkout main && git pull origin main
   # edit package.json → "version": "<NEW_VERSION_NO_V>"
   git add package.json
   git commit -m "v<NEW_VERSION>"
   git push origin main
   ```

2. The push triggers `.github/workflows/release.yaml`:
   - Reads `package.json` version → constructs `backend_tag=v<version>`.
   - Downloads `openapi.yaml` from the matching backend GitHub release.
   - Runs `./generate-sdk.sh openapi.yaml` to regenerate the
     TypeScript-axios client into `src/`.
   - `npm install && npm run build` produces `dist/`.
   - `npm publish` pushes to npm with the new version.

   ```bash
   gh -R platzio/sdk-js run watch <run-id>
   ```

   ⚠️ **Wait point.** npm publishes are also effectively irrevocable
   (you can `npm unpublish` only within 72 hours, and only if no other
   package depends on the version). If the publish step fails, fix
   forward with the next patch version.

3. Verify at <https://www.npmjs.com/package/@platzio/sdk>.

### When the backend version doesn't match

If the user wants `sdk-js` to point at a backend version other than its
own `package.json` version, create a `version-override.txt` file at the
root of `sdk-js` containing the desired backend version (no leading
`v`). The workflow reads that file first. This is an escape hatch for
republishing the SDK without bumping its visible version, or for
generating against a backend pre-release. Don't use it in routine
releases — it makes the npm version ↔ backend version mapping
non-obvious.

## Phase 4 — Update the helm chart

Edit `../helm-charts/charts/platzio/Chart.yaml`:

```yaml
apiVersion: v2
appVersion: "<NEW_VERSION>"     # e.g. "0.6.9"
version: "<NEW_VERSION>"        # same as appVersion
description: A Helm chart for Platz.io
name: platzio
type: application
# ...
annotations:
  artifacthub.io/prerelease: "false"    # or "true" if beta
  artifacthub.io/changes: |
    - kind: added
      description: <short release note item>
    - kind: changed
      description: <short release note item>
    - kind: fixed
      description: <short release note item>
```

Conventions:

- **`version` and `appVersion` always match.** Both are the chart's
  release version, without a leading `v`.
- **`prerelease`** is `"true"` for beta versions (the `-beta.N` suffix),
  `"false"` otherwise. Quoted strings, not booleans.
- **`changes`** uses the [artifacthub
  schema](https://artifacthub.io/docs/topics/annotations/helm/): `kind`
  is one of `added` / `changed` / `removed` / `fixed` / `security` /
  `deprecated`. Keep each entry short — these surface in
  ArtifactHub's UI; the full prose lives in the site blog post later.
- **Don't sneak in unrelated items.** Only ship release notes for what
  actually changed in this version's commits.

Then edit `../helm-charts/charts/platzio/values.yaml` and bump the
image tags:

```yaml
images:
  frontend:
    repository: platzio/frontend
    tag: <FRONTEND_TAG>     # new tag if frontend changed, else previous
  backend:
    repository: platzio/backend
    tag: <BACKEND_TAG>      # new tag if backend changed, else previous
  helm:
    repository: platzio/base
    tag: <BASE_IMAGE_TAG>   # almost always the same as before
```

Only bump the ones that have new tags from Phase 2. Reuse the existing
tag verbatim for the others.

Commit both files in one commit:

```bash
cd ../helm-charts
git add charts/platzio/Chart.yaml charts/platzio/values.yaml
git commit -m "<NEW_VERSION>"
git push origin main
```

The chart-releaser GitHub Actions workflow at
`.github/workflows/release.yml` picks up the push to main, packages the
chart, and creates a `platzio-<version>` GitHub release plus an
`index.yaml` update on `gh-pages`. **No manual tagging required** —
chart-releaser creates the `platzio-<version>` tag itself.

⚠️ **Wait point.** Verify the release exists at
`https://github.com/platzio/helm-charts/releases` and the chart's index
includes the new version
(`https://platzio.github.io/helm-charts/index.yaml`). Takes about a
minute.

## Phase 5 — Update the Terraform module

`platzio/terraform-aws-platzio` pins the helm chart version in two
places. Both must move together.

1. **`modules/main/variables.tf`** — change the `default` of the
   `chart_version` variable:

   ```hcl
   variable "chart_version" {
     description = "Helm chart version to install/upgrade"
     type        = string
     default     = "<NEW_VERSION>"     # no leading v
   }
   ```

2. **`README.md`** — update every `?ref=v<OLD>/modules/...` reference
   to point at the new tag:

   ```bash
   cd ../terraform-aws-platzio
   sed -i.bak "s|?ref=v<OLD_VERSION>|?ref=v<NEW_VERSION>|g" README.md && rm README.md.bak
   ```

   Sanity-check the diff before staging — sed can match unintended
   substrings if the version string isn't unique enough.

Commit, tag with `v<NEW_VERSION>` (with the leading `v`, matching this
repo's tag style), push:

```bash
git add modules/main/variables.tf README.md
git commit -m "v<NEW_VERSION>"
git tag "v<NEW_VERSION>"
git push origin main
git push origin "v<NEW_VERSION>"
```

There's no CI here that builds a release artifact — the tag itself is
the release.

## Phase 6 — Blog post + docs PR in `../site`

`platzio/site` is PR-only with publish-on-merge — see
[[feedback-site-pr-only]]. Branch off main, commit, push, open PR. Do
**not** push to main directly.

### Write the post

Create `../site/blog/<YYYY-MM-DD>-v<NEW_VERSION>.md`. Match the style
of recent posts (sample the last 3 with
`ls -1 ../site/blog/ | tail -5`).

Mandatory structure:

```md
---
slug: v<NEW_VERSION>
title: Version <NEW_VERSION> Released
tags: [releases]
---

<one or two sentence intro>

{/* truncate */}

## <Theme heading per major change>

<body>

## <Next theme>

<body>
```

Notes:

- **Slug** is `v<version>` (with leading `v`), matching the existing
  blog URL convention.
- **Title** is "Version `<version>` Released" verbatim. Don't reword
  ("Releasing v0.6.9", "Platz v0.6.9", etc. — keep it consistent with
  the archive).
- **Truncate marker** is the MDX form `{/* truncate */}`. Do not write
  `<!-- truncate -->` (HTML comment); Docusaurus prefers the MDX form
  in `.md` files in this project.
- **Don't list every commit.** Group changes thematically — backend
  changes, frontend changes, chart changes, terraform changes — and
  pick the meaningful ones. The Chart.yaml `artifacthub.io/changes`
  list is the terse version; the blog post is the prose.
- **Thank external contributors.** Look at `git log
  v<OLD>..v<NEW>` across all the repos and pick out commits authored
  by people who aren't core maintainers. Mention them with their
  GitHub @-handle and link to their profile. The historical convention
  is either `> Thanks to [@username](https://github.com/username) for
  this contribution!` blockquote at the start of the section, or
  `*Thanks @username for this contribution!*` italic inline. Either
  is fine; copy whichever the most recent blog post used.
- **Match the prose tone.** Look at the most recent 3-4 posts. The
  voice is direct, factual, no marketing language. Don't say
  "exciting new feature"; say what it does.

### Doc updates

If the release introduces user-facing behavior changes, update the
relevant pages under `../site/docs/guide/` in the same PR. Run
`npm run format` (see [[feedback-markdown-formatting]]) before
committing — the site repo's CI rejects unformatted markdown.

### Open the PR

```bash
cd ../site
git checkout -b release/v<NEW_VERSION>
git add blog/<YYYY-MM-DD>-v<NEW_VERSION>.md docs/guide/...
npm run format
git add -u
git commit -m "Add v<NEW_VERSION> release notes"
git push -u origin "release/v<NEW_VERSION>"
gh pr create --base main \
  --title "v<NEW_VERSION> release notes" \
  --body "$(cat <<EOF
Adds the blog post and any associated doc updates for v<NEW_VERSION>.

See:
- Helm chart: https://github.com/platzio/helm-charts/releases/tag/platzio-<NEW_VERSION>
- Terraform: https://github.com/platzio/terraform-aws-platzio/releases/tag/v<NEW_VERSION>
EOF
)"
```

Merging this PR triggers the site's publish workflow and the release
goes live on platz.io.

## Phase 7 — Verify the whole chain

After the site PR is merged:

1. **Helm chart pull** — `helm pull oci://...` works, or `helm repo
   update && helm search repo platzio` shows the new version.
2. **Terraform `?ref=...`** — a fresh clone of the module at the new
   tag references the right chart version.
3. **crates.io** — <https://crates.io/crates/platz-sdk> shows the new
   version (if sdk-rs was released).
4. **npm** — <https://www.npmjs.com/package/@platzio/sdk> shows the
   new version (if sdk-js was released).
5. **Blog post** — `https://platz.io/blog/v<NEW_VERSION>` loads.
6. **ArtifactHub** — within 30 min, the platzio chart on ArtifactHub
   updates to the new version and shows the change list.

Open issues or follow-up PRs for anything that's broken before walking
away.

## Variations and edge cases

### Only the helm chart changed

Sometimes the only thing that needs releasing is a chart values change
(e.g., a default resource limit tweak). In that case skip Phases 1, 2
and 3 entirely — bump only the chart's `version` (`appVersion` stays
the same, since the binaries didn't move) and the prerelease / changes
annotations. Reuse all three image tags from the previous values.yaml,
and don't re-publish the SDKs.

### Beta → stable transition

When the user wants to promote `vX.Y.Z-beta.N` to `vX.Y.Z`, the
backend / frontend / base-image likely don't have any new commits
since the last beta. That's fine — reuse the beta's image tags
verbatim in the helm chart, just bump the chart's `version` to the
stable string and flip `artifacthub.io/prerelease` to `"false"`. The
SDKs usually get the matching stable version as well (publish a new
sdk-rs tag + sdk-js push to mirror the version even if the code is
unchanged from the beta).

### Hot-fix on an old release

Out of scope for this skill — see whoever's currently doing release
management. The forward-only pattern documented here doesn't address
backporting.

### A repo's release CI failed

If the backend or frontend release workflow fails (e.g., a flaky
Docker Hub push), the tag exists but the image doesn't. Two options:

- **Delete the tag and retry.** `git push --delete origin <tag>`,
  `git tag -d <tag>` locally, then re-tag and push. The release
  workflow re-runs from scratch.
- **Re-run the workflow.** `gh -R platzio/<repo> run rerun
  <run-id>`. Faster if the failure was transient.

## Checklist (copy into the conversation when starting)

```
- [ ] Phase 0: confirm release type + version with user
- [ ] Phase 1: check changes in backend, frontend, base-image, sdk-rs, sdk-js
- [ ] Phase 2: tag and push backend / frontend / base-image; wait for CI
- [ ] Phase 3: sync sdk-rs to backend API collections, tag + push; bump sdk-js package.json; wait for publishes
- [ ] Phase 4: bump Chart.yaml + values.yaml; commit + push; wait for chart-releaser
- [ ] Phase 5: bump terraform variables.tf + README.md; commit, tag, push
- [ ] Phase 6: write blog post; thank contributors; mention new SDK versions; open site PR
- [ ] Phase 7: verify end-to-end (incl. crates.io and npm)
```
