#!/usr/bin/env bash
# Local scraper + processor for the contrast CI dashboard.
# Produces per-tier data files so the dashboard can render 5 tabs:
#   nightly / pr / scheduled / manual / release
# Each tier aggregates jobs from one or more workflows.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [ -f .env.local ]; then
    set -a
    # shellcheck disable=SC1091
    source .env.local
    set +a
fi
if [ -z "${GH_TOKEN:-}" ]; then
    echo "GH_TOKEN not set (expected in .env.local)" >&2
    exit 1
fi
export GH_TOKEN

REPO="edgelesssys/contrast"
DAYS=14
MAX_RUNS_PER_WORKFLOW=15
MAX_LOGS_PER_TIER=40

# tier => space-separated workflow filenames
declare -A TIER_WORKFLOWS=(
    [nightly]="e2e_nightly.yml"
    [pr]="e2e_on_pull_request.yml e2e_badaml.yml e2e_attestation.yml e2e_service_mesh.yml imagepuller-benchmark.yml"
    [scheduled]="k3s_compatibility.yml rim_updates.yml e2e_runtime-reproducibility.yml"
    [manual]="e2e_manual.yml release.yml"
    [release]="release_publish.yml pr_release_artifacts.yml"
)
TIERS=(nightly pr scheduled manual release)

if date -v-1d +%Y-%m-%d >/dev/null 2>&1; then
    SINCE=$(date -v-${DAYS}d +%Y-%m-%d)
else
    SINCE=$(date -d "${DAYS} days ago" +%Y-%m-%d)
fi

fetch_tier() {
    local tier=$1
    local workflows=${TIER_WORKFLOWS[$tier]}
    echo ">>> tier=$tier workflows=$workflows"

    echo '[]' > "all-jobs-${tier}.json"
    for wf in $workflows; do
        echo "  .. $wf"
        if ! gh api \
            -H "Accept: application/vnd.github+json" \
            --paginate \
            "repos/${REPO}/actions/workflows/${wf}/runs?created=>${SINCE}&per_page=50" \
            --jq '.workflow_runs' 2>/dev/null | jq -s 'add // []' > "runs-${tier}-${wf}.json"; then
            echo "     (workflow not found or no runs; skipping)"
            echo '[]' > "runs-${tier}-${wf}.json"
            continue
        fi
        local n
        n=$(jq 'length' "runs-${tier}-${wf}.json")
        echo "     $n runs"

        for run_id in $(jq -r ".[0:${MAX_RUNS_PER_WORKFLOW}] | .[].id" "runs-${tier}-${wf}.json"); do
            if ! gh api \
                -H "Accept: application/vnd.github+json" \
                --paginate \
                "repos/${REPO}/actions/runs/${run_id}/jobs?per_page=100&filter=all" \
                --jq '.jobs[]' 2>/dev/null | \
                jq -s --arg run_id "$run_id" --arg wf "$wf" --arg tier "$tier" \
                    '[.[] | . + {workflow_run_id: $run_id, source_workflow: $wf, tier: $tier}]' > run-jobs.json; then
                echo "     (failed to fetch run $run_id; skipping)"
                continue
            fi
            jq -s 'add' "all-jobs-${tier}.json" run-jobs.json > temp-jobs.json
            mv temp-jobs.json "all-jobs-${tier}.json"
        done
    done

    echo '{"jobs":' > "raw-runs-${tier}.json"
    cat "all-jobs-${tier}.json" >> "raw-runs-${tier}.json"
    echo '}' >> "raw-runs-${tier}.json"
    echo "  total $tier jobs: $(jq '.jobs | length' "raw-runs-${tier}.json")"

    # logs for failed jobs (capped)
    mkdir -p "job-logs-${tier}"
    local count=0
    for job_id in $(jq -r '.jobs[] | select(.conclusion == "failure") | .id' "raw-runs-${tier}.json"); do
        count=$((count+1))
        [ $count -gt $MAX_LOGS_PER_TIER ] && break
        local out="job-logs-${tier}/${job_id}.log"
        [ -s "$out" ] && continue
        curl -sL \
            -H "Authorization: token ${GH_TOKEN}" \
            -H "Accept: application/vnd.github+json" \
            "https://api.github.com/repos/${REPO}/actions/jobs/${job_id}/logs" \
            -o "$out"
    done
    echo "  $count log files fetched"
}

process_tier() {
    local tier=$1
    echo ">>> processing tier=$tier"

    # process-data.js reads hard-coded filenames; stage this tier's data into them.
    cp "raw-runs-${tier}.json" raw-runs.json
    rm -rf job-logs
    cp -R "job-logs-${tier}" job-logs

    # placeholders so process-data.js does not error on missing optional inputs
    echo '[]' > coco-charts-runs.json
    echo '[]' > coco-charts-jobs.json
    echo '[]' > coco-caa-runs.json
    echo '[]' > coco-caa-jobs.json
    echo '[]' > s390x-runs.json
    echo '[]' > s390x-jobs.json
    cat > required-tests.yaml <<'EOF'
required_tests: []
EOF

    # wipe prior data.json so the weather window for this tier is clean
    rm -f data.json
    NODE_OPTIONS="--max-old-space-size=6144" node scripts/process-data.js > /dev/null
    mv data.json "data-${tier}.json"
    echo "  wrote data-${tier}.json"
}

fetch_all() {
    echo ">> Fetching since $SINCE across all tiers"
    for tier in "${TIERS[@]}"; do
        fetch_tier "$tier"
    done
}

fetch_pr_flakes() {
    local since_flaky
    if date -v-7d +%Y-%m-%d >/dev/null 2>&1; then
        since_flaky=$(date -v-7d +%Y-%m-%d)
    else
        since_flaky=$(date -d "7 days ago" +%Y-%m-%d)
    fi
    echo ">>> PR flake scrape since $since_flaky"

    gh api -H "Accept: application/vnd.github+json" --paginate \
        "repos/${REPO}/actions/workflows/e2e_on_pull_request.yml/runs?event=pull_request&created=>${since_flaky}&per_page=100" \
        --jq '[.workflow_runs[] | select(.conclusion != "skipped")]' | jq -s 'add // []' > pr-runs.json
    echo "  $(jq 'length' pr-runs.json) PR runs"

    gh api "repos/${REPO}/pulls?state=all&per_page=100" \
        --jq '[.[] | {branch: .head.ref, number: .number, title: .title, merged: (.merged_at != null), state: .state, merged_at: .merged_at}]' > pr-cache.json

    echo '[]' > all-pr-jobs.json
    for run_id in $(jq -r 'sort_by(.created_at) | reverse | .[0:25] | .[].id' pr-runs.json); do
        local run_info pr_number head_sha display_title run_attempt created_at pr_info pr_merged pr_state
        run_info=$(jq -r --arg id "$run_id" '.[] | select(.id == ($id | tonumber))' pr-runs.json)
        pr_number=$(echo "$run_info" | jq -r '.pull_requests[0].number // null')
        head_sha=$(echo "$run_info" | jq -r '.head_sha // "unknown"')
        display_title=$(echo "$run_info" | jq -r '.display_title // "unknown"')
        run_attempt=$(echo "$run_info" | jq -r '.run_attempt // 1')
        created_at=$(echo "$run_info" | jq -r '.created_at')
        pr_info=$(jq -r --arg title "$display_title" '[.[] | select(.title == $title)] | .[0] // empty' pr-cache.json)
        if [ "$pr_number" = "null" ] || [ -z "$pr_number" ]; then
            pr_number=$(echo "$pr_info" | jq -r '.number // empty' 2>/dev/null)
        fi
        pr_merged=$(echo "$pr_info" | jq -r '.merged // false' 2>/dev/null)
        pr_state=$(echo "$pr_info" | jq -r '.state // empty' 2>/dev/null)
        [ -z "$pr_number" ] && continue

        gh api -H "Accept: application/vnd.github+json" --paginate \
            "repos/${REPO}/actions/runs/${run_id}/jobs?per_page=100&filter=all" \
            --jq '.jobs[]' | \
            jq -s --arg run_id "$run_id" --arg pr "$pr_number" --arg title "$display_title" \
                  --arg sha "$head_sha" --arg attempt "$run_attempt" --arg created "$created_at" \
                  --arg merged "$pr_merged" --arg state "$pr_state" \
            '[.[] | . + {workflow_run_id: $run_id, pr_number: $pr, pr_title: $title, head_sha: $sha,
                         run_attempt: ($attempt | tonumber), run_created_at: $created,
                         pr_merged: ($merged == "true"), pr_state: $state}]' > run-jobs.json
        jq -s 'add' all-pr-jobs.json run-jobs.json > temp-jobs.json
        mv temp-jobs.json all-pr-jobs.json
    done

    echo '{"jobs":' > raw-pr-runs.json
    cat all-pr-jobs.json >> raw-pr-runs.json
    echo '}' >> raw-pr-runs.json
    echo "  $(jq '.jobs | length' raw-pr-runs.json) PR jobs"

    mkdir -p pr-job-logs
    local count=0
    for job_id in $(jq -r '.jobs[] | select(.conclusion == "failure") | .id' raw-pr-runs.json); do
        count=$((count+1))
        [ $count -gt 30 ] && break
        local out="pr-job-logs/${job_id}.log"
        [ -s "$out" ] && continue
        curl -sL -H "Authorization: token ${GH_TOKEN}" -H "Accept: application/vnd.github+json" \
            "https://api.github.com/repos/${REPO}/actions/jobs/${job_id}/logs" -o "$out"
    done

    NODE_OPTIONS="--max-old-space-size=4096" node scripts/process-flaky-data.js > /dev/null
    echo "  wrote flaky-data.json"
}

process_all() {
    [ -d node_modules ] || npm install --no-audit --no-fund > /dev/null
    for tier in "${TIERS[@]}"; do
        process_tier "$tier"
    done

    # Legacy data.json for backward compat (mirror nightly)
    cp data-nightly.json data.json
    echo ">> produced data-{nightly,pr,scheduled,manual,release}.json"
}

serve() {
    PORT=${PORT:-8088}
    echo ">> http://localhost:${PORT}  (Ctrl-C to stop)"
    npx --yes http-server "$SCRIPT_DIR" -p "$PORT" -c-1
}

case "${1:-both}" in
    fetch) fetch_all; process_all ;;
    process) process_all ;;
    flakes) fetch_pr_flakes ;;
    serve) serve ;;
    both) fetch_all; process_all; serve ;;
    tier)
        t=${2:?Usage: $0 tier <nightly|pr|scheduled|manual|release>}
        fetch_tier "$t"
        process_tier "$t"
        ;;
    *) echo "Usage: $0 [fetch|process|flakes|serve|both|tier <name>]"; exit 1 ;;
esac
