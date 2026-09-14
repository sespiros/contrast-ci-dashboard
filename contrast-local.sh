#!/usr/bin/env bash
# Local scraper + processor for the contrast CI dashboard.
# Produces per-tier data files for the dashboard tabs:
#   release-nightly / e2e-nightly / scheduled
# Each tier aggregates jobs from one or more workflows.
#
# release-nightly and e2e-nightly are two views over the same parent
# workflow, release_nightly.yml. The parent invokes the e2e_nightly
# reusable workflow (matrix tests) plus artifact build and an
# e2e_release matrix. The two tabs slice that single run by job-name
# prefix (see TIER_JOB_FILTER below).
#
# Do NOT add release.yml / release_promote.yml here. Those are
# manual-dispatch release workflows that share the same job-name
# prefixes (release-requirement: e2e nightly / …) because they use
# the same reusables, so scraping them would silently mix manual
# release runs into the nightly view.

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
JOBS_PAGE_SIZE=50
JOBS_FETCH_RETRIES=4
RUNS_CACHE_DIR="${TMPDIR:-/tmp}/contrast-ci-dashboard-runs-$$"
JOBS_CACHE_DIR="${TMPDIR:-/tmp}/contrast-ci-dashboard-jobs-$$"
mkdir -p "$RUNS_CACHE_DIR" "$JOBS_CACHE_DIR"
trap 'rm -rf "$RUNS_CACHE_DIR" "$JOBS_CACHE_DIR"' EXIT

# tier => space-separated workflow filenames
declare -A TIER_WORKFLOWS=(
    [release-nightly]="release_nightly.yml"
    [e2e-nightly]="release_nightly.yml"
    # pr_release_artifacts is weekly, so it belongs with the sparse-cadence
    # scheduled tier (which keeps the last real status) rather than the
    # nightly-cadence release tier (which would flag it Missing 6 days a week).
    [scheduled]="rim_updates.yml e2e_runtime-reproducibility.yml pr_release_artifacts.yml"
)
TIERS=(release-nightly e2e-nightly scheduled)

# Per-tier jq filter applied to each job after fetch. The pipeline runs
# as `[ .[] | <filter> ]`. Use it to keep / drop / rename job names so
# the tier sees only the slice it cares about.
#
#   e2e-nightly   = jobs inside the e2e_nightly reusable, excluding the
#                   prep jobs that gate the matrix but aren't tests:
#                   per-platform "maintenance <platform>" jobs, the
#                   "Build cleanup-bare-metal image" job, and the
#                   "Notify teams channel of failure" job. Strip the
#                   "release-requirement: e2e nightly / " prefix, then
#                   collapse the per-test name doubling: the
#                   e2e_nightly_platform matrix job and the e2e.yml test
#                   job it calls share the same name, so a test renders as
#                   "<platform> / <test> / <test>"; drop the duplicate
#                   trailing segment so names match config.yaml's
#                   "<platform> / <test>".
#   release-nightly = everything else from release_nightly.yml plus the
#                     e2e_nightly prep jobs (maintenance + image build),
#                     since their failures are what skip the whole pipeline.
#
# scheduled has no filter; all jobs flow through unchanged.
declare -A TIER_JOB_FILTER=(
    [e2e-nightly]='select(.name | startswith("release-requirement: e2e nightly / ")) | select((.name | startswith("release-requirement: e2e nightly / maintenance ")) | not) | select((.name | startswith("release-requirement: e2e nightly / Build cleanup-bare-metal image")) | not) | select((.name | startswith("release-requirement: e2e nightly / Notify teams channel")) | not) | .name |= ltrimstr("release-requirement: e2e nightly / ") | .name |= (split(" / ") | if (length >= 2 and .[-1] == .[-2]) then .[:-1] else . end | join(" / "))'
    [release-nightly]='select(((.name | startswith("release-requirement: e2e nightly / ")) | not) or (.name | startswith("release-requirement: e2e nightly / maintenance ")) or (.name | startswith("release-requirement: e2e nightly / Build cleanup-bare-metal image")))'
)

# Workflows we want scoped to a single branch. Most should be
# main-only so feature-branch workflow_dispatch runs (e.g.
# automated/nvidia-rim-updates or one-off CI experiments) don't
# pollute the dashboard. The intentional exception is
# release_publish.yml, which fires on tag pushes and would return
# zero runs under any branch filter.
declare -A WORKFLOW_BRANCH_FILTER=(
    [release_nightly.yml]="main"
    [k3s_compatibility.yml]="main"
    [rim_updates.yml]="main"
    [e2e_runtime-reproducibility.yml]="main"
    [pr_release_artifacts.yml]="main"
)

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
        local branch_qs=""
        local branch="${WORKFLOW_BRANCH_FILTER[$wf]:-}"
        if [ -n "$branch" ]; then
            branch_qs="&branch=${branch}"
            echo "  .. $wf (branch=$branch)"
        else
            echo "  .. $wf"
        fi
        if ! fetch_workflow_runs "$wf" "$branch_qs" > "runs-${tier}-${wf}.json"; then
            echo "     (workflow not found or no runs; skipping)"
            echo '[]' > "runs-${tier}-${wf}.json"
            continue
        fi
        local n
        n=$(jq 'length' "runs-${tier}-${wf}.json")
        echo "     $n runs"

        for run_id in $(jq -r ".[0:${MAX_RUNS_PER_WORKFLOW}] | .[].id" "runs-${tier}-${wf}.json"); do
            if ! fetch_run_jobs "$run_id" "$wf" "$tier" > run-jobs.json; then
                echo "     failed to fetch jobs for run $run_id; aborting to avoid publishing partial data" >&2
                return 1
            fi
            if [ "$tier" = "release-nightly" ]; then
                synthesize_nightly_aggregate < run-jobs.json > run-jobs.tmp && mv run-jobs.tmp run-jobs.json
            fi
            jq -s 'add' "all-jobs-${tier}.json" run-jobs.json > temp-jobs.json
            mv temp-jobs.json "all-jobs-${tier}.json"
        done
    done

    local filter="${TIER_JOB_FILTER[$tier]:-}"
    if [ -n "$filter" ]; then
        local before after
        before=$(jq 'length' "all-jobs-${tier}.json")
        jq "[ .[] | ${filter} ]" \
           "all-jobs-${tier}.json" > "all-jobs-${tier}.tmp" && \
            mv "all-jobs-${tier}.tmp" "all-jobs-${tier}.json"
        after=$(jq 'length' "all-jobs-${tier}.json")
        echo "  filter applied ($after jobs retained, was $before)"
    fi

    # Matrix-template placeholder rows (a skipped matrix job whose name still
    # holds the literal "${{ ... }}") are kept: process-data.js fans them out
    # onto the concrete job names and renders them as blocked, see
    # expandPlaceholderJobs there.

    echo '{"jobs":' > "raw-runs-${tier}.json"
    cat "all-jobs-${tier}.json" >> "raw-runs-${tier}.json"
    echo '}' >> "raw-runs-${tier}.json"
    echo "  total $tier jobs: $(jq '.jobs | length' "raw-runs-${tier}.json")"

    # logs for failed jobs (capped)
    mkdir -p "job-logs-${tier}"
    local count=0
    for job_id in $(jq -r '.jobs[] | select(.conclusion == "failure" and .synthetic != true) | .id' "raw-runs-${tier}.json"); do
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

cache_key() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

fetch_workflow_runs() {
    local wf=$1
    local branch_qs=$2
    local key cache_file
    key=$(cache_key "${wf}${branch_qs}")
    cache_file="${RUNS_CACHE_DIR}/${key}.json"

    if [ ! -s "$cache_file" ]; then
        gh api \
            -H "Accept: application/vnd.github+json" \
            --paginate \
            "repos/${REPO}/actions/workflows/${wf}/runs?created=>${SINCE}&per_page=50${branch_qs}" \
            --jq '.workflow_runs' 2>/dev/null | jq -s 'add // []' > "$cache_file"
    else
        echo "     using cached runs for $wf" >&2
    fi

    cat "$cache_file"
}

# The "nightly" job in release_nightly.yml calls the e2e_nightly reusable
# workflow, and its result alone decides whether the e2e release matrix runs.
# GitHub's jobs API lists only the leaf jobs inside a reusable workflow, never
# the caller, so that gate has no row of its own. Synthesize one per run
# attempt from the leaves, mirroring how GitHub derives a called workflow's
# conclusion: any failure -> failure, else any cancelled -> cancelled, else
# success (skipped leaves don't fail the caller); in progress while any leaf
# is still running. The row carries synthetic=true and a string id so log
# fetching and job links skip it (the link goes to the run instead), and
# one pseudo step per red leaf so the dashboard's "failed step" names the
# jobs that actually blocked the release.
NIGHTLY_AGGREGATE_NAME="release-requirement: e2e nightly"
synthesize_nightly_aggregate() {
    jq --arg name "$NIGHTLY_AGGREGATE_NAME" --arg repo "$REPO" '
      (map(select(.name | startswith($name + " / ")))) as $leaves
      | if ($leaves | length) == 0 then . else
        $leaves[0] as $j
        | (if any($leaves[]; .status != "completed") then "in_progress" else "completed" end) as $status
        | (if $status != "completed" then null
           elif any($leaves[]; .conclusion == "failure" or .conclusion == "timed_out") then "failure"
           elif any($leaves[]; .conclusion == "cancelled") then "cancelled"
           else "success" end) as $conclusion
        | . + [{
            id: ("synthetic-nightly-" + ($j.run_id | tostring) + "-" + (($j.run_attempt // 1) | tostring)),
            synthetic: true,
            name: $name,
            status: $status,
            conclusion: $conclusion,
            run_id: $j.run_id,
            run_attempt: $j.run_attempt,
            run_url: $j.run_url,
            workflow_name: $j.workflow_name,
            head_branch: $j.head_branch,
            head_sha: $j.head_sha,
            html_url: ("https://github.com/" + $repo + "/actions/runs/" + ($j.run_id | tostring)),
            created_at: ([$leaves[].created_at] | min),
            started_at: ([$leaves[].started_at | select(. != null)] | min),
            completed_at: (if $status == "completed" then ([$leaves[].completed_at | select(. != null)] | max) else null end),
            steps: ([$leaves[] | select(.conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "cancelled")
                     | {name: (.name | ltrimstr($name + " / ") | split(" / ")
                               | if (length >= 2 and .[-1] == .[-2]) then .[:-1] else . end | join(" / ")),
                        status: "completed", conclusion: "failure"}]
                    | unique_by(.name)),
            labels: [],
            workflow_run_id: $j.workflow_run_id,
            source_workflow: $j.source_workflow,
            tier: $j.tier
          }]
      end'
}

fetch_run_jobs() {
    local run_id=$1
    local wf=$2
    local tier=$3
    local page=1
    local combined="[]"
    local cache_file="${JOBS_CACHE_DIR}/${run_id}.json"

    if [ -s "$cache_file" ]; then
        echo "     using cached jobs for run $run_id" >&2
        jq --arg run_id "$run_id" --arg wf "$wf" --arg tier "$tier" \
            '[.[] | . + {workflow_run_id: $run_id, source_workflow: $wf, tier: $tier}]' "$cache_file"
        return
    fi

    while true; do
        local response=""
        local ok=0

        for attempt in $(seq 1 "$JOBS_FETCH_RETRIES"); do
            if response=$(gh api \
                -H "Accept: application/vnd.github+json" \
                "repos/${REPO}/actions/runs/${run_id}/jobs?per_page=${JOBS_PAGE_SIZE}&page=${page}&filter=all"); then
                ok=1
                break
            fi

            echo "     run $run_id jobs page $page failed (attempt $attempt/${JOBS_FETCH_RETRIES}); retrying" >&2
            sleep $((attempt * 2))
        done

        if [ "$ok" -ne 1 ]; then
            return 1
        fi

        local page_jobs page_count
        page_jobs=$(printf '%s' "$response" | jq '.jobs // empty') || return 1
        page_count=$(printf '%s' "$page_jobs" | jq 'length') || return 1

        combined=$(jq -s '.[0] + .[1]' <(printf '%s' "$combined") <(printf '%s' "$page_jobs")) || return 1

        [ "$page_count" -lt "$JOBS_PAGE_SIZE" ] && break
        page=$((page + 1))
    done

    printf '%s' "$combined" > "$cache_file"

    jq --arg run_id "$run_id" --arg wf "$wf" --arg tier "$tier" \
        '[.[] | . + {workflow_run_id: $run_id, source_workflow: $wf, tier: $tier}]' "$cache_file"
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
    # The nightly tiers come from release_nightly.yml (20:15 UTC cron). Bucket
    # their jobs by cron day (offset 20h15m = 72900000ms) so a run that spans
    # UTC midnight stays in one day-slot and lines up with the frontend's
    # cron-day "today". Other tiers bucket by plain UTC day (offset 0).
    local bucket_offset=0
    case "$tier" in
        e2e-nightly|release-nightly) bucket_offset=72900000 ;;
    esac
    NODE_OPTIONS="--max-old-space-size=6144" NIGHTLY_BUCKET_OFFSET_MS="$bucket_offset" \
        node scripts/process-data.js > /dev/null
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

    # Legacy data.json for backward compat (mirror e2e-nightly)
    cp data-e2e-nightly.json data.json
    echo ">> produced data-{release-nightly,e2e-nightly,scheduled}.json"
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
        t=${2:?Usage: $0 tier <release-nightly|e2e-nightly|scheduled>}
        fetch_tier "$t"
        process_tier "$t"
        ;;
    *) echo "Usage: $0 [fetch|process|flakes|serve|both|tier <name>]"; exit 1 ;;
esac
