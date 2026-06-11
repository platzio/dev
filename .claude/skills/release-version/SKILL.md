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

Cutting a Platzio release touches many sibling repos in a specific
order. Each step has wait points where you're blocked on an upstream
CI run; do **not** proceed past a wait point until the build completes.

The ordering isn't arbitrary — it follows the dependency graph between
the repos, so an upstream is always released and its consumers
re-pinned before the downstream is tagged:

1. **chart-ext** is a crates.io dependency of backend → bump it first,
   then bump backend's `platz-chart-ext` pin in `Cargo.toml` before
   tagging backend.
2. **backend** uploads `openapi.yaml` to its GitHub release → tag it
   after chart-ext but before sdk-js.
3. **sdk-js** and **sdk-py** are generated from backend's `openapi.yaml`
   → publish them after backend. sdk-js is also an npm dependency of
   frontend, so bump frontend's `@platzio/sdk` pin before tagging
   frontend.
4. **frontend** image is referenced by the helm chart → tag it before
   the chart bump.

If you skip ahead, the downstream release will ship against the old
upstream and you'll need a redo.

Sibling repos used here, relative to `dev/`:

- `../backend` — Rust workspace.
- `../frontend` — Vue SPA.
- `../base-image` — Alpine base used by the helm pod. Rarely bumps.
- `../sdk-rs` — Rust SDK published to crates.io as `platz-sdk`.
- `../sdk-js` — TypeScript SDK published to npm as `@platzio/sdk`.
  Auto-generated from the backend's OpenAPI schema.
- `../sdk-py` — Python SDK published to PyPI as `platz`. Auto-generated
  from the backend's OpenAPI schema (like sdk-js), built and published
  with `uv` via PyPI trusted publishing.
- `../chart-ext` — Rust crate defining the chart-extension schema. Tag
  releases; its `Cargo.toml` version must match the tag and track the
  backend's `major.minor` (no `-beta` qualifier). See Phase 2.
- `../helm-charts` — the `platzio` chart.
- `../terraform-aws-platzio` — Terraform module.
- `../site` — public docs + blog (PR-only; see [[feedback-site-pr-only]]).

## The change cascade — which repos a change forces

The dependency order above also decides **which repos must release**,
not just the sequence they release in. A change never stays contained
to the repo it landed in — it forces a fresh release of everything
downstream of it, including repos that have no commits of their own.
Find the highest repo in the chain that changed, then release it and
everything below it:

1. **chart-ext changed → backend must be rebuilt.** Releasing chart-ext
   re-pins backend's `platz-chart-ext` dependency (Phase 2), and that
   re-pin is itself a new backend commit — so backend gets a new tag
   even if it had no other commits of its own.
2. **backend released → all three SDKs must be released.** A new backend
   build is a new API version, so `sdk-rs`, `sdk-js`, **and** `sdk-py`
   all ship with the matching backend version. This is mandatory: there is no
   "the API surface didn't change, so the SDK can sit out" exception. If
   backend ships a tag, the SDKs ship the matching version.
3. **sdk-js released → frontend must be rebuilt.** Frontend pins
   `@platzio/sdk`; bump the pin, then **build and lint locally**
   (`npm run build`) to prove the regenerated types didn't break
   anything, and only then tag the frontend.
4. **frontend / backend / base-image images exist → do the umbrella
   release.** Once the images are published, continue to the release
   part: the helm chart (Phase 6), the Terraform module (Phase 7), and
   the site blog + docs (Phase 8).

So the only genuine judgment call is at the **top** of the chain — did
chart-ext or backend actually change? Everything downstream of a change
is mechanical: it ships, with a version matching the backend's. The one
repo outside this cascade is `base-image`: it's a build input, not a
downstream consumer, so it's released only when its own source changed
(and it rarely does).

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
`../sdk-js`, `../chart-ext`, run:

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

`sdk-js` doesn't keep git tags — it tracks `package.json` `version`.
**Release it whenever the backend is released**, with the matching
version (see [[The change cascade]] above): a new backend build is a new
API version, and `sdk-js` is auto-generated from the backend's OpenAPI
schema, so consumers expect the npm version to match the backend version
they target. Re-generation is cheap and there is no "the OpenAPI surface
didn't change, so skip it" exception — if backend ships a tag, `sdk-js`
ships the matching version.

`sdk-py` works exactly like `sdk-js`: no git tags, it tracks
`pyproject.toml` `version`, is auto-generated from the backend's OpenAPI
schema, and **releases whenever the backend is released** with the
matching version. One wrinkle: PyPI uses PEP 440, so the `X.Y.Z-beta.N`
value in `pyproject.toml` publishes as `X.Y.ZbN` (e.g. `0.7.0-beta.3` →
`0.7.0b3`). Keep the `pyproject.toml` value in the `-beta.N` spelling that
mirrors the backend tag; the workflow derives the backend tag as
`v<version>` from it. Phase 4c covers the mechanics.

`sdk-rs` is a hand-maintained Rust crate. **Release it whenever the
backend is released**, with the matching version — a new backend build
is a new API version, and the SDKs must never lag it (see [[The change
cascade]] above). This is mandatory: there is no "the API surface didn't
change, so sdk-rs can sit out" exception. If backend ships a tag, sdk-rs
ships the matching version. The only time sdk-rs releases *without* a
backend release is when it has standalone commits of its own on
`../sdk-rs/main` since its last `v...` tag.

Because it's hand-maintained (no codegen from OpenAPI), each release is
also a maintenance pass to keep the SDK aligned with the backend's API
surface — otherwise the SDK drifts and consumers can't reach newer
collections. Phase 4a covers the sync work.

`chart-ext` is a Rust crate. **Release it whenever there are commits on
`../chart-ext/main` since its last `v...` tag** — this is the top of the
dependency cascade, so a chart-ext release is not optional: it forces a
backend rebuild (Phase 2 re-pins backend's `platz-chart-ext`), which in
turn forces both SDKs and the frontend (see [[The change cascade]]
above). Its version is **not** the backend version verbatim — it tracks
the backend's **`major.minor` only**, with its own patch number and
**never** a `-beta` qualifier.
So for a backend release of `v0.7.0-beta.2` (or `v0.7.0`), chart-ext's
target is `v0.7.<patch>`, where `<patch>` is the next patch above
chart-ext's last `v0.7.*` tag (or `.0` if `0.7` is new). Phase 2
covers the version-bump mechanics (and the follow-on bump to
backend's `platz-chart-ext` dependency).

Save the result as a small table you'll refer to throughout the rest of
the workflow:

| Repo       | Old tag / version | New tag / version | Notes                  |
| ---------- | ----------------- | ----------------- | ---------------------- |
| backend    | v0.6.8            | v0.6.9            | (or "unchanged")       |
| frontend   | v0.6.0            | v0.6.0            | (unchanged — reuse)    |
| base-image | v8                | v8                | (unchanged — reuse)    |
| sdk-rs     | v0.6.3            | v0.6.4            | (hand-maintained)      |
| sdk-js     | 0.6.1             | 0.6.9             | (matches backend ver.) |
| sdk-py     | 0.6.1             | 0.6.9             | (matches backend ver.) |
| chart-ext  | v0.6.2            | v0.6.3            | (major.minor = backend)|

### Inventory new settings and flags

While walking the commit log of each repo, separately note **any new
configuration the release introduces**: env vars, CLI flags, config
file keys, feature toggles. These have to be propagated downstream —
the helm chart, the terraform module, and the docs all need to learn
about them, or operators won't be able to use the new behavior. Keep a
running list as you read the commits:

| Repo    | New setting        | Type     | Default      | Notes                       |
| ------- | ------------------ | -------- | ------------ | --------------------------- |
| backend | `PLATZ_FOO_TOKEN`  | env var  | (none)       | required if foo enabled     |
| backend | `--enable-bar`     | CLI flag | false        | gates the bar subsystem     |

How to find them efficiently:

- **Backend (Rust):** look for additions to `clap` derive structs in
  the relevant binary's `main.rs` / `Args` struct, additions to
  `envy`/`serde` config structs, and any new `std::env::var(...)`
  calls. `git diff $LAST_TAG..origin/main -- '*.rs' | grep -E '(#\[arg|#\[clap|env::var|#\[serde\(rename)'`
  is a fast first pass.
- **Frontend (Vue):** look for new keys read from `window.config` /
  build-time env, since those are populated by the helm chart's
  config template.

This inventory drives the **new-settings checklist** referenced in
Phases 6, 7, and 8. Don't skip it — settings that ship in the
binaries but not in the chart values are invisible to operators
running via helm, and that's a common release-day miss.

### Release notes accumulate across the whole beta cycle

Release notes — both the `artifacthub.io/changes` list in `Chart.yaml`
(Phase 6) and the blog post (Phase 8) — must describe everything that
changed since the **last stable release**, not just since the last tag.

A version ships as a series of betas before its stable cut:
`v0.7.0-beta.1`, `v0.7.0-beta.2`, …, then `v0.7.0`. **Always add up the
notes across the betas:** when you write the notes for any beta, include
that beta's changes *on top of* every earlier beta in the same cycle —
the notes accumulate, they don't reset each beta. By the time you cut
the stable `v0.7.0`, its notes are the **union of every beta's notes**
for the whole cycle, so an operator who only ever installs stable
releases still sees the complete changelog.

Concretely, when computing the change list for notes, diff against the
**last stable tag**, not `LAST_TAG`:

```bash
cd ../backend
# last stable tag = newest tag with no -beta suffix
LAST_STABLE=$(git tag --sort=-creatordate | grep -vE -- '-beta' | head -1)
git log "${LAST_STABLE}..origin/main" --oneline
```

(The `LAST_TAG..origin/main` range from the table above is still the
right one for deciding *which repos need a new tag*. It's only the
release-notes range that must reach back to the last stable.)

It helps to keep a running notes list across the cycle — append each
beta's items rather than rewriting, and carry the accumulated list
forward into the stable Chart.yaml annotation and blog post.

## Phase 2 — Release `chart-ext`, then bump backend's dep

Skip this phase if Phase 1 found no commits on `../chart-ext/main` since
its last tag.

This phase runs **before** Phase 3 tags the backend: backend's
`workspace.dependencies.platz-chart-ext` pins a specific crates.io
`version = "..."`, so a new chart-ext must be on crates.io and pinned
in backend's `Cargo.toml` *before* backend is tagged — otherwise the
backend release ships against the old chart-ext.

Unlike backend / frontend / base-image, chart-ext is **not** a
tag-only release: the crate carries its version in `Cargo.toml`, and
that version **must equal the tag** (minus the leading `v`). So you
bump `Cargo.toml`, rebuild to refresh `Cargo.lock`, commit, *then*
tag — the commit and the tag move together. If you tag without bumping
`Cargo.toml`, the published crate's version won't match its tag.

### Step 1: Pick the chart-ext version

chart-ext tracks the backend's **`major.minor` only**, with its own
patch and **no `-beta` suffix**:

```bash
cd ../chart-ext
git checkout main && git pull origin main
git fetch origin --tags
# BACKEND_MM = major.minor of the backend version being released,
#   e.g. backend v0.7.0-beta.2  ->  BACKEND_MM=0.7
# Find chart-ext's latest tag on that major.minor line:
git tag --list "v${BACKEND_MM}.*" --sort=-v:refname | head -1
```

- If a `v${BACKEND_MM}.*` tag exists, increment its patch
  (`v0.7.3` → `v0.7.4`).
- If `${BACKEND_MM}` is a new line for chart-ext (no matching tag),
  start at `v${BACKEND_MM}.0`.

Call the result `CHART_EXT_VERSION` (e.g. `0.7.4`) and the tag
`v${CHART_EXT_VERSION}`.

### Step 2: Bump chart-ext `Cargo.toml`, rebuild, commit, tag, push

```bash
cd ../chart-ext
# edit Cargo.toml -> version = "<CHART_EXT_VERSION>"   (no leading v)
cargo build                       # refreshes Cargo.lock with the new version
git add Cargo.toml Cargo.lock
git commit -m "v<CHART_EXT_VERSION>"
git tag "v<CHART_EXT_VERSION>"
git push origin main
git push origin "v<CHART_EXT_VERSION>"
```

`cargo build` (not just `cargo check`) is what rewrites the crate's own
entry in `Cargo.lock` to the new version; stage the resulting
`Cargo.lock` change alongside `Cargo.toml` so the two never drift.
Confirm the bump landed before tagging:

```bash
grep '^version' Cargo.toml          # must equal CHART_EXT_VERSION
# confirm the crate's own entry in Cargo.lock moved too (use the
# package name from Cargo.toml's [package] name, which may differ
# from the repo name):
PKG=$(grep -m1 '^name' Cargo.toml | sed 's/.*"\(.*\)".*/\1/')
grep -A1 "name = \"${PKG}\"" Cargo.lock     # must show the same version
```

The tag push triggers `.github/workflows/release.yml` which publishes
to crates.io. Watch it and treat it as a wait point:

```bash
gh -R platzio/chart-ext run list --branch "v<CHART_EXT_VERSION>" --limit 1
gh -R platzio/chart-ext run watch <run-id>
```

⚠️ **Wait point.** Step 3 below bumps backend's pinned version, and
`cargo build` will refuse to resolve a chart-ext version that isn't
yet visible on crates.io. Verify at
<https://crates.io/crates/platz-chart-ext> before continuing.

### Step 3: Bump backend's `platz-chart-ext` dependency

```bash
cd ../backend
git checkout main && git pull origin main
# edit Cargo.toml's [workspace.dependencies.platz-chart-ext] block:
#   version = "<CHART_EXT_VERSION>"
cargo build                       # refreshes Cargo.lock to pull the new chart-ext
git add Cargo.toml Cargo.lock
git commit -m "Bump platz-chart-ext to <CHART_EXT_VERSION>"
git push origin main
```

This commit must land on backend's main **before** Phase 3 tags the
backend, so the backend release ships against the new chart-ext.
If the new chart-ext changed its API surface, `cargo build` may
surface compile errors in backend code — fix them in this same
commit rather than splitting them across two backend commits.

## Phase 3 — Align backend versions, then tag and push backend / base-image

### Align the backend's in-tree versions first

A git tag doesn't change the versions baked into a repo's source. The backend
workspace crates each carry their own `version` in `Cargo.toml`, and that feeds
`CARGO_PKG_VERSION` — which is exactly what `utoipa` reports as the OpenAPI
`info.version`. That version flows downstream into the published `openapi.yaml`,
the rendered API reference on the docs site, and the generated SDKs. If you tag
`v0.7.0-beta.4` but leave the crates at `0.1.0`, the schema advertises `0.1.0`
and the crate metadata misstates the release.

**Invariant: every repo's in-tree version must equal the release version, not
just the git tag.** Bump the backend crates *before* tagging:

```bash
cd ../backend
git checkout main && git pull origin main

# Set every workspace member's [package] version to the release version
# (no leading v, keep the beta suffix, e.g. 0.7.0-beta.4). `cargo set-version`
# (from cargo-edit) does the whole workspace in one shot:
cargo install cargo-edit --quiet 2>/dev/null || true
cargo set-version --workspace "<NEW_VERSION_NO_V>"
#   …or, without cargo-edit, edit each member crate's [package] version by hand:
#   api, auth, db, k8s-agent, chart-discovery, resource-sync, status-updates, otel.

cargo build                       # refresh Cargo.lock with the new versions
# verify the bump — every member crate must show the release version:
grep -rn '^version' Cargo.toml */Cargo.toml | grep -v '\[workspace'
```

`cargo set-version --workspace` moves only the member crates' own versions; it
leaves `[workspace.dependencies]` pins like `platz-chart-ext` alone (those are
dependency requirements, not this workspace's version). Eyeball the diff to be
sure nothing else moved, then commit:

```bash
git add -A
git commit -m "v<NEW_VERSION>"
git push origin main
```

> `base-image` has no `Cargo.toml`/`package.json` version to align — it uses the
> `v1`, `v2`, … image scheme, so there's nothing to bump for it; go straight to
> tagging it below.

### Tag and push

For each repo that has changes (backend, base-image):

```bash
cd ../<repo>
git checkout main
git pull origin main      # backend: also picks up the version-bump commit above
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
successfully — Phase 4's sdk-js publish reads `openapi.yaml` from the
backend's GitHub release, and the helm chart's image references won't
exist on Docker Hub yet either. Backend's multi-arch build takes
~20 minutes on native runners; base-image ~2 minutes.

**Frontend is not tagged here** — see Phase 5. Frontend pins
`@platzio/sdk`, so its tag must come after sdk-js publishes (Phase 4)
and frontend's `package.json` is bumped against the new sdk-js.

If the workflow fails, fix the underlying issue, delete the tag locally
*and* on origin (`git push --delete origin <tag>`), re-tag, push again.

## Phase 4 — Release the SDKs

The SDKs publish to public package registries. They must be released
**after** Phase 3 (specifically, after the backend's release CI
finishes), because `sdk-js` and `sdk-py` download `openapi.yaml` from the
backend's GitHub release as part of their own builds.

### 4a. sdk-rs (`platz-sdk` on crates.io)

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

### 4b. sdk-js (`@platzio/sdk` on npm), then bump frontend

`sdk-js` is **always** released right after backend, because the npm
SDK is auto-generated from the backend's OpenAPI schema. Consumers
expect the npm version to match the backend version they're targeting.

Crucially, **frontend pins `@platzio/sdk` in `package.json`** — so a
frontend build picks up SDK type changes (driven by OpenAPI schema
changes) only after its pin is bumped. This phase publishes sdk-js,
then bumps frontend's pin on main; Phase 5 then tags the frontend
against that bumped commit.

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

4. **Bump frontend's `@platzio/sdk` pin.** Once the new sdk-js is live
   on npm, update frontend's pinned version so the next frontend build
   pulls the new SDK (and its regenerated TypeScript types):

   ```bash
   cd ../frontend
   git checkout main && git pull origin main
   # edit package.json → "@platzio/sdk": "^<NEW_VERSION_NO_V>"
   npm install                                # refresh package-lock.json
   git add package.json package-lock.json
   git commit -m "Bump @platzio/sdk to <NEW_VERSION>"
   git push origin main
   ```

   If the SDK's regenerated types break frontend code (renamed
   operations, removed fields, stricter optional/required), fix the
   call sites in this same commit. **Don't move on to Phase 5 until
   the frontend builds locally** (`npm run build`) — a broken main is
   the last thing you want to tag.

### 4c. sdk-py (`platz` on PyPI)

`sdk-py` is the Python SDK. Like `sdk-js` it's auto-generated from the
backend's `openapi.yaml` and published whenever the backend is released,
with the matching version. Unlike sdk-js it is **not** a frontend
dependency, so there's no downstream pin to bump.

1. Bump `pyproject.toml` to the new backend version in `-beta.N` spelling
   (no leading `v`):

   ```bash
   cd ../sdk-py
   git checkout main && git pull origin main
   # edit pyproject.toml → version = "<NEW_VERSION>"   (e.g. 0.7.0-beta.3)
   git add pyproject.toml
   git commit -m "v<NEW_VERSION>"
   git push origin main
   ```

   For the **first** release the version is already set to the target, so
   there's no bump to commit — trigger the workflow manually instead:

   ```bash
   gh -R platzio/sdk-py workflow run release.yaml --ref main
   ```

2. The push (or manual dispatch) triggers
   `.github/workflows/release.yaml`:
   - Reads `pyproject.toml` version → constructs `backend_tag=v<version>`.
   - Downloads `openapi.yaml` from the matching backend GitHub release.
   - Runs `./generate-sdk.sh openapi.yaml` to regenerate the `platz/`
     package with `openapi-python-client` (run via `uv`).
   - `uv build` produces the sdist + wheel.
   - `uv publish` uploads to PyPI via **trusted publishing** (OIDC; no
     token). `--check-url` makes it a no-op if the version already exists,
     so a re-run or a non-version push to main is harmless.

   ```bash
   gh -R platzio/sdk-py run watch <run-id>
   ```

   ⚠️ **Wait point.** PyPI publishes are irrevocable — a deleted version
   can't be re-uploaded under the same filename. If the publish step
   fails, fix forward with the next version. The generate step emits two
   benign warnings (dropped `oneOf` inline arms — see sdk-py's AGENTS.md);
   they're expected and do not fail the build.

3. PyPI normalizes the version to PEP 440 (`0.7.0-beta.3` → `0.7.0b3`).
   Verify at <https://pypi.org/project/platz/>; betas install with
   `pip install --pre platz`.

### When the backend version doesn't match

If the user wants `sdk-js` to point at a backend version other than its
own `package.json` version, create a `version-override.txt` file at the
root of `sdk-js` containing the desired backend version (no leading
`v`). The workflow reads that file first. This is an escape hatch for
republishing the SDK without bumping its visible version, or for
generating against a backend pre-release. Don't use it in routine
releases — it makes the npm version ↔ backend version mapping
non-obvious.

`sdk-py` has the identical `version-override.txt` escape hatch — its
workflow reads it before `pyproject.toml`. Same caveat applies.

## Phase 5 — Align frontend version, then tag and push

Skip this phase if Phase 1 found no commits on `../frontend/main` since
its last tag **and** Phase 4 didn't bump `@platzio/sdk`. Otherwise
(which is almost always — see Phase 4's "always released right after
backend" rule), align the frontend's in-tree version and tag it now that
its `package.json` pins the new SDK version.

Like the backend, the frontend is otherwise tag-only, so its
`package.json` `version` drifts (it has sat at `0.1.0`) unless you bump
it here. Per the **in-tree version invariant** (Phase 3), set it to the
release version before tagging:

```bash
cd ../frontend
git checkout main
git pull origin main      # picks up the @platzio/sdk bump from Phase 4

# Set package.json (and package-lock.json) to the release version, no tag/commit:
npm version "<NEW_VERSION_NO_V>" --no-git-tag-version
git add package.json package-lock.json
git commit -m "v<NEW_VERSION>"
git push origin main

git tag "${NEW_TAG}"
git push origin "${NEW_TAG}"
```

(You can fold the `npm version` bump into the Phase 4 `@platzio/sdk`
pin commit instead of making a separate commit — just make sure the
version lands on `main` before the tag.)

Frontend's release workflow is `v**` tag-triggered:

```bash
gh -R platzio/frontend run list --branch "${NEW_TAG}" --limit 1
gh -R platzio/frontend run watch <run-id>
```

⚠️ **Wait point.** Phase 6's helm chart sets the `frontend` image tag
to `${NEW_TAG}` and pulls from Docker Hub at install time. The build
must finish before the chart's release. Frontend builds take ~5 min.

If the workflow fails, fix the underlying issue, delete the tag
(`git push --delete origin <tag>`), re-tag, push again.

## Phase 6 — Update the helm chart

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
      description: "<short release note item>"
    - kind: changed
      description: "<short release note item>"
    - kind: fixed
      description: "<short release note item>"
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
- **Always wrap each `description:` in double quotes.** Artifact Hub
  validates each `description:` and rejects unquoted strings containing
  any of:

  ```
  {}:[],&*#?|-<>=!%@
  ```

  Since most of our descriptions reference component names with hyphens
  (`chart-discovery`, `k8s-agent`, `resource-sync`) or include `=` / `,`
  inside parentheses, every entry needs quotes:

  ```yaml
  - kind: added
    description: "extraEnv on api, chart-discovery, k8s-agent"
  ```

  An unquoted entry will surface as a scan error on Artifact Hub
  (`invalid changes annotation`) after release, even though Helm itself
  accepts it.
- **Accumulate across the beta cycle.** The `changes` list isn't just
  the delta since the previous tag — it's everything since the last
  *stable* release (see [[Release notes accumulate across the whole
  beta cycle]] in Phase 1). Each beta's list builds on the prior betas',
  and the stable release's list is the union of all of them.
- **Don't sneak in unrelated items.** Within that range, only ship
  release notes for what actually changed in this release's commits.

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

Only bump the ones that have new tags from Phase 3 (backend,
base-image) or Phase 5 (frontend). Reuse the existing tag verbatim
for the others.

### Wire in any new settings from Phase 1's inventory

Before committing, walk the **new-settings inventory** from Phase 1
and make sure each entry is exposed by the chart:

- **New env vars / CLI flags** → add a default key under the relevant
  section of `values.yaml` (e.g. `backend.env`, `backend.config`),
  and reference it from the corresponding template under
  `charts/platzio/templates/` so it actually reaches the pod. A
  setting that lives in `values.yaml` but isn't templated through is
  dead weight — search the templates dir for similar existing
  settings to mirror the wiring pattern.
- **New required settings** → if a setting has no sensible default,
  either pick one and document it, or fail fast in the template with
  `{{ required "..." }}` so misconfiguration is loud instead of
  silent at runtime.
- **Sensitive values** (tokens, keys) → follow the chart's existing
  secret pattern (usually `existingSecret` + key name rather than
  inlining the value). Never default a secret to a non-empty string.

Reflect each newly exposed setting in `artifacthub.io/changes` as a
`kind: added` entry so operators see it in the chart's changelog.

### Update the chart README

`charts/platzio/README.md` **is the chart's ArtifactHub page** —
ArtifactHub renders this file (not the repo-root README) as the body of
the chart's listing. If it's stale or empty, the listing looks broken
to anyone evaluating Platz.

Walk through it as part of every release and update what's drifted:

- **Parameters tables.** Every entry in Phase 1's new-settings
  inventory that was wired into `values.yaml` above must also appear
  in the README's parameters tables (one per section: Images, Auth,
  Database, API, Frontend, k8s-agent, chart-discovery, …). Match the
  key name, type, default, and a one-line description. If a setting
  was removed or renamed, fix the table — don't leave dead entries.
- **TL;DR / install / uninstall snippets.** If the release changes
  how operators install (new required secret, new mandatory value,
  changed default ingress wiring), update the runnable snippets too.
- **Concepts and workloads.** The "Introduction" section enumerates
  Platz's workloads and the concept glossary. New workers, new
  providers, or renamed concepts belong there.
- **Configuration details sections.** "Multi-cluster deployments",
  "Chart discovery", "Ingress and `ownUrlOverride`", etc. — read
  these against the release's actual behavior and fix anything that
  no longer matches.

Don't put release-specific change notes in the README — that's what
`artifacthub.io/changes` is for. The README describes the chart as it
exists *at this version*; it isn't a changelog.

**Heading emoji convention.** The chart README (and Platzio docs in
general) decorate `#` and `##` headings with a leading emoji, placed
at the **start** of the line — not the end. `###` headings stay plain
so the parameters tables don't turn into a wall of emoji. Use 🕸️ for
Platz itself (the top-level title), 👋 for the welcoming "Introduction"
section, and pick a tasteful emoji that matches the section's topic
for the rest (⚡ TL;DR, ✅ Prerequisites, 📦 Installing, 🧹
Uninstalling, ⚙️ Parameters, 🛠️ Configuration details, ⬆️ Upgrading,
📚 Documentation, ⚖️ License). When you add a new top-level section,
pick an emoji in the same spirit — don't leave a heading bare and
don't double up emojis on a single line.

Commit Chart.yaml, values.yaml, and README.md together:

```bash
cd ../helm-charts
git add charts/platzio/Chart.yaml charts/platzio/values.yaml charts/platzio/README.md
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

## Phase 7 — Update the Terraform module

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

### Expose any new settings as Terraform variables

For each entry in Phase 1's new-settings inventory that was wired into
the helm chart in Phase 6, decide whether the Terraform module should
expose it too:

- **Cluster-wide, operator-tunable settings** (timeouts, replica
  counts, feature toggles, integration tokens) → add a corresponding
  `variable` in `modules/main/variables.tf` and plumb it through
  `modules/main/main.tf` into the `helm_release` resource's `set`
  blocks. Match the variable name and default to the chart's key
  where reasonable.
- **Internal-only settings** that operators shouldn't touch → leave
  them out of Terraform; the chart default is enough.
- **New required settings** → make the Terraform variable required
  (omit `default`) and document it in the README's inputs table.

Update `README.md`'s inputs table for every variable you add or
change. Mention them in the new-tag commit message as well so the
release diff is self-documenting.

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

## Phase 8 — Blog post + docs PR in `../site`

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
- **Cover the whole beta cycle, not just the last delta.** Like the
  Chart.yaml `changes` list, the post accumulates across betas: diff
  from the last *stable* tag (see [[Release notes accumulate across the
  whole beta cycle]] in Phase 1), so the stable post covers every change
  shipped across all of this cycle's betas. A stable post that only
  describes the delta since the final beta — often nothing — is a miss.
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

**Document every entry from Phase 1's new-settings inventory.** For
each new env var / CLI flag / chart value / Terraform variable, find
the right page under `../site/docs/` and add it: the configuration
reference for env vars and flags, the helm/values reference for chart
values, and the Terraform module page for new module variables. If a
new setting has no obvious home page, it's a signal that one of those
reference docs is missing a section — add it. Operators reading the
release blog post should be able to click through to actionable docs;
landing on "this setting exists but isn't documented anywhere" is the
worst outcome.

The chart's own README (`charts/platzio/README.md`) is the
parameters table that ships with the chart on ArtifactHub — Phase 6
keeps it in sync. The site docs duplicate-but-elaborate: link to
relevant guide pages from the blog post rather than repeating the
ArtifactHub parameters reference verbatim.

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

**Stop here. Do not merge the PR yourself** — even when CI is green and
Phase 9's blog-post check needs the post live, the merge is the user's
call. The site's `main` is protected against direct pushes specifically
because merging publishes immediately to platz.io; the human approval
*is* the editorial review. Surface the PR URL, note that Phase 9 will
fail on the blog-post URL until it's merged, and wait. Treat this as
non-negotiable: do not call `gh pr merge` on `platzio/site` under any
circumstance.

## Phase 9 — Verify the whole chain

After the site PR is merged:

1. **Helm chart pull** — `helm pull oci://...` works, or `helm repo
   update && helm search repo platzio` shows the new version.
2. **Terraform `?ref=...`** — a fresh clone of the module at the new
   tag references the right chart version.
3. **crates.io** — <https://crates.io/crates/platz-sdk> shows the new
   version (if sdk-rs was released).
4. **npm / PyPI** — <https://www.npmjs.com/package/@platzio/sdk> shows
   the new sdk-js version, and <https://pypi.org/project/platz/> shows the
   new sdk-py version (PEP 440 form, e.g. `0.7.0b3`), if the SDKs were
   released.
5. **Blog post** — `https://platz.io/blog/v<NEW_VERSION>` loads.
6. **ArtifactHub** — within 30 min, the platzio chart on ArtifactHub
   updates to the new version and shows the change list.
7. **In-tree versions match the tag** — the backend release's
   `openapi.yaml` advertises the release version, and the frontend tag's
   `package.json` does too. A lingering `0.1.0` means the Phase 3 / 5
   bump was missed:

   ```bash
   curl -sSL "https://github.com/platzio/backend/releases/download/<NEW_TAG>/openapi.yaml" \
     | grep -A2 '^info:'                       # version: must be <NEW_VERSION>
   git -C ../frontend show "<NEW_TAG>:package.json" | grep '"version"'
   ```

Open issues or follow-up PRs for anything that's broken before walking
away.

## Variations and edge cases

### Only the helm chart changed

Sometimes the only thing that needs releasing is a chart values change
(e.g., a default resource limit tweak). In that case skip Phases 1
through 5 entirely (no chart-ext bump, no backend/base-image/frontend
tag, no SDK publish) — bump only the chart's `version` (`appVersion`
stays the same, since the binaries didn't move) and the
prerelease / changes annotations. Reuse all three image tags from the
previous `values.yaml`, and don't re-publish the SDKs.

### Beta → stable transition

When the user wants to promote `vX.Y.Z-beta.N` to `vX.Y.Z`, the
backend / frontend / base-image likely don't have any new commits
since the last beta. That's fine — reuse the beta's image tags
verbatim in the helm chart (Phase 6), just bump the chart's `version`
to the stable string and flip `artifacthub.io/prerelease` to `"false"`.
The SDKs **must** get the matching stable version as well (publish a
new sdk-rs tag + sdk-js push + sdk-py push to mirror the version even if
the code is unchanged from the beta) — the stable cut is a new backend
tag, and a new backend tag always forces matching SDK releases (see
[[The change cascade]]). When sdk-js republishes for stable, still bump frontend's
`@platzio/sdk` pin per Phase 4 step 4 so the repo points at the stable
SDK; you can then skip tagging the frontend in Phase 5 if it had no
other commits, and the chart's frontend image stays at the beta tag.

On the **in-tree version invariant** (Phases 3 / 5): when you reuse the
beta's images verbatim for a stable cut, you are deliberately *not*
rebuilding the backend/frontend, so their in-tree `Cargo.toml` /
`package.json` versions stay at the last beta string — that's expected,
since the chart points at the beta image tag. Only bump-and-re-tag the
backend/frontend (forcing a fresh image build that bakes in `vX.Y.Z`)
if you specifically want the stable version compiled into the binaries;
otherwise the beta-versioned image is the released stable artifact.

**The release notes are the gotcha here.** Diffing from the last beta
shows little or nothing, but the stable release's notes must be the
**sum of every beta in the cycle** — compute them from the last
*stable* tag, per [[Release notes accumulate across the whole beta
cycle]] in Phase 1. Carry the accumulated Chart.yaml `changes` list and
the accumulated blog content forward into the stable cut; don't write a
near-empty stable changelog just because the final beta added little.

chart-ext is the exception: because it only tracks `major.minor` and
never carries a `-beta` suffix, a beta → stable promotion within the
same `major.minor` (e.g. `v0.7.0-beta.2` → `v0.7.0`) leaves
chart-ext's target unchanged. Skip Phase 2 entirely unless chart-ext
itself had new commits — there's no version to bump.

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
- [ ] Phase 1: check changes in backend, frontend, base-image, sdk-rs, sdk-js, chart-ext; inventory new settings/flags
- [ ] Phase 2 (if chart-ext changed): bump chart-ext Cargo.toml (backend major.minor, no beta), cargo build, commit, tag matching version, push, wait for crates.io publish; then bump backend's platz-chart-ext version in Cargo.toml, cargo build, commit, push to backend main
- [ ] Phase 3: bump backend workspace crate versions to the release version (`cargo set-version --workspace`), cargo build, commit, push; then tag and push backend / base-image (NOT frontend); wait for backend CI (uploads openapi.yaml)
- [ ] Phase 4: sync sdk-rs to backend API collections, tag + push; bump sdk-js package.json, push, wait for npm publish; bump sdk-py pyproject.toml (or `gh workflow run` for the first release), wait for PyPI publish; then bump frontend's @platzio/sdk pin, npm install, commit, push to frontend main
- [ ] Phase 5: bump frontend package.json version to the release version (`npm version --no-git-tag-version`), commit, push; tag and push frontend; wait for CI
- [ ] Phase 6: bump Chart.yaml + values.yaml; accumulate changes notes across all betas (diff from last stable); wire new settings into values + templates; update charts/platzio/README.md (ArtifactHub page) — parameters tables, install snippets, concepts; commit + push; wait for chart-releaser
- [ ] Phase 7: bump terraform variables.tf + README.md; expose new chart values as module variables; commit, tag, push
- [ ] Phase 8: write blog post accumulating all beta notes across the cycle; thank contributors; mention new SDK versions; document every new setting/flag; open site PR
- [ ] Phase 9: verify end-to-end (incl. crates.io and npm)
```
