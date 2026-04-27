# Contrast CI Dashboard

A static dashboard for monitoring the [Contrast](https://github.com/edgelesssys/contrast) CI health.
Forked from [kata-containers/ci-dashboard](https://github.com/kata-containers/ci-dashboard) (Apache-2.0).

Live: <https://sespiros.github.io/contrast-ci-dashboard/>

## Tabs

| Tab | Source workflow(s) | What it shows |
|---|---|---|
| **Nightly** | `e2e_nightly.yml` | Full bare-metal matrix grid (rows = test, columns = last 10 nightlies) per platform |
| **Nightly Failures** | (aggregated from Nightly) | Per-job failure breakdown across platforms over the window |
| **Scheduled** | `k3s_compatibility.yml`, `rim_updates.yml`, `e2e_runtime-reproducibility.yml` | Flat list of recent runs |
| **Release** | `release_publish.yml`, `pr_release_artifacts.yml` | Flat list of release-artifact runs |

The Nightly tab has platform pills that scope the grid to one of the four matrix combinations: SNP (palutena), TDX (olimar), SNP+GPU (discovery), TDX+GPU (dgx-007).

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
./contrast-local.sh tier nightly   # refresh a single tier
```

## Deployment

Lives on GitHub Pages, refreshed every 3 hours by `.github/workflows/refresh-data.yml`.
The workflow uses the default `secrets.GITHUB_TOKEN` (no PAT required): the scraper only hits public endpoints on `edgelesssys/contrast`, which authenticated installation tokens can read regardless of org SAML enforcement.
It runs the same scraper used locally, commits any updated `data-*.json` back to the active branch, and publishes the static site via the Pages deploy action.

Pages source must be set to **GitHub Actions** in repo settings.

## Configuration

`config.yaml` enumerates the four bare-metal nightly platforms and the test-name list per platform.
Update it whenever a test-name lands or moves in `e2e_nightly.yml`'s matrix; then run `./contrast-local.sh process` (no scrape needed) to re-bake `data-nightly.json`.

`fatal_steps` controls which step name counts as a "real test failure" vs an infrastructure flake (currently `E2E Test.*`, matching `e2e.yml`).

## License

Apache-2.0. See `LICENSE` and `NOTICE`.
