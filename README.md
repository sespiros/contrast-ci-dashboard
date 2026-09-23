# Contrast CI Dashboard

A static dashboard for monitoring the [Contrast](https://github.com/edgelesssys/contrast) CI health.
Forked from [kata-containers/ci-dashboard](https://github.com/kata-containers/ci-dashboard) (Apache-2.0).

Live: <https://sespiros.github.io/contrast-ci-dashboard/>

## Tabs

| Tab | Source workflow(s) | What it shows |
|---|---|---|
| **Release nightly** | `release_nightly.yml` (non-matrix jobs + maintenance), `pr_release_artifacts.yml` | Artifact build, e2e release matrix, and the e2e_nightly maintenance jobs whose failure can skip the whole pipeline |
| **e2e nightly** | `release_nightly.yml` (matrix jobs only, maintenance excluded) | Full bare-metal matrix grid (rows = test, columns = last 10 nightlies) per platform |
| **Scheduled** | `k3s_compatibility.yml`, `rim_updates.yml`, `e2e_runtime-reproducibility.yml` | Flat list of recent runs |

The e2e nightly tab has platform pills that scope the grid to one of the four matrix combinations: SNP (palutena), TDX (olimar), SNP+GPU (discovery), TDX+GPU (b13-gs01).

Both nightly-derived tabs scrape the same parent workflow (`release_nightly.yml`). The split between them is purely by job-name prefix: anything under `release-requirement: e2e nightly /` belongs to e2e nightly, except `release-requirement: e2e nightly / maintenance /` which stays on Release nightly because those jobs gate whether the matrix runs at all.

## Architecture

```
contrast-local.sh
   ├── for each tier: gh api ➜ raw-runs-<tier>.json + job-logs-<tier>/
   └── for each tier: scripts/process-data.js ➜ data-<tier>.json

index.html / app.js / style.css  ➜ static site loads data-*.json on demand
```

## Local development

```sh
# one-time: drop your SAML-authorized PAT (Actions: Read on edgelesssys/contrast)
echo 'GH_TOKEN=ghp_xxx' > .env.local
chmod 600 .env.local

# scrape + process all tiers + serve on http://localhost:8088
./contrast-local.sh both

# subcommands
./contrast-local.sh fetch     # scrape + process, no server
./contrast-local.sh process   # only re-run process-data.js (after config edits)
./contrast-local.sh serve     # serve existing data
./contrast-local.sh tier e2e-nightly   # refresh a single tier (release-nightly | e2e-nightly | scheduled)
```

## Deployment

Lives on GitHub Pages, refreshed by `.github/workflows/refresh-data.yml` on cron (hourly 00:23-09:23 UTC, then every 3 hours).
GitHub drops many of those scheduled runs, so while the release nightly is in progress the workflow re-dispatches itself every ~20 minutes until it has scraped the finished run.
The workflow uses the default `secrets.GITHUB_TOKEN` (no PAT required): the scraper only hits public endpoints on `edgelesssys/contrast`, which authenticated installation tokens can read regardless of org SAML enforcement.
It runs the same scraper used locally, keeps the `data-*.json` files as a 90-day workflow artifact, and publishes the static site via the Pages deploy action.

Pages source must be set to **GitHub Actions** in repo settings.

## Configuration

`config.yaml` enumerates the four bare-metal nightly platforms and the test-name list per platform.
Update it whenever a test-name lands or moves in `e2e_nightly.yml`'s matrix; then run `./contrast-local.sh process` (no scrape needed) to re-bake `data-e2e-nightly.json`.

`fatal_steps` controls which step name counts as a "real test failure" (currently `E2E Test.*`, matching `e2e.yml`).
A job that fails at any other step is shown as "Infra failed": it ran, so it isn't missing, but it produced no test verdict.

## License

Apache-2.0. See `LICENSE` and `NOTICE`.
