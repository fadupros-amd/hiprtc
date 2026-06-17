#!/bin/bash
# Local orchestrator: push latest scripts to GitHub, then trigger run via LUMI → Adastra.
# Usage: ADASTRA_PASSWORD='...' bash basilisk_hip_test.sh
set -euo pipefail

# -----------------------------------------------------------------------
# Config
# -----------------------------------------------------------------------
LUMI_USER=fabdupros
LUMI_HOST=lumi.csc.fi
LUMI_KEY="$HOME/Mobaxterm/Home/.ssh/FD_moba_lockhart"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LUMI_TMP="/users/fabdupros/tmp/basilisk_hip_${TIMESTAMP}"

# Password must be in environment — never echoed
if [[ -z "${ADASTRA_PASSWORD:-}" ]]; then
    echo "ERROR: ADASTRA_PASSWORD env var not set."
    echo "Usage: ADASTRA_PASSWORD='<password>' bash basilisk_hip_test.sh"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Basilisk HIP test workflow ==="
echo "Timestamp: $TIMESTAMP"
echo "LUMI tmp:  $LUMI_TMP"
echo ""

lumi_run() {
    ssh -i "$LUMI_KEY" -o StrictHostKeyChecking=accept-new \
        "${LUMI_USER}@${LUMI_HOST}" "$@"
}
lumi_scp() {
    scp -i "$LUMI_KEY" -o StrictHostKeyChecking=accept-new "$@"
}

# -----------------------------------------------------------------------
# Step 1: Push latest scripts to GitHub so Adastra clones fresh code
# -----------------------------------------------------------------------
echo "--- Pushing latest scripts to GitHub ---"
cd "$SCRIPT_DIR"
git add -A
if ! git diff --cached --quiet; then
    git commit -m "$(cat <<EOF
Update scripts for run $TIMESTAMP

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
    git push origin master
    echo "Pushed."
else
    echo "No changes to push — repo is up to date."
fi
cd - > /dev/null

# -----------------------------------------------------------------------
# Step 2: Create tmp dir on LUMI and SCP the expect script
# -----------------------------------------------------------------------
echo "--- Preparing LUMI ---"
lumi_run "mkdir -p ${LUMI_TMP}"
lumi_scp "$SCRIPT_DIR/basilisk_main.exp" "${LUMI_USER}@${LUMI_HOST}:${LUMI_TMP}/"

# -----------------------------------------------------------------------
# Step 3: Run expect script on LUMI (password passed via env, not args)
# -----------------------------------------------------------------------
echo "--- Running expect on LUMI → Adastra ---"
lumi_run "
    export APWD='${ADASTRA_PASSWORD}'
    export ATIMESTAMP='${TIMESTAMP}'
    export LUMI_TMP='${LUMI_TMP}'
    expect ${LUMI_TMP}/basilisk_main.exp
"

# -----------------------------------------------------------------------
# Step 4: Fetch results from LUMI to local
# -----------------------------------------------------------------------
LOCAL_RESULTS="$SCRIPT_DIR/results/run_${TIMESTAMP}"
mkdir -p "$LOCAL_RESULTS"
echo "--- Fetching results from LUMI ---"
lumi_scp -r \
    "${LUMI_USER}@${LUMI_HOST}:${LUMI_TMP}/results_${TIMESTAMP}/" \
    "$LOCAL_RESULTS/" 2>/dev/null || echo "WARNING: no results to fetch (check LUMI logs)"

# -----------------------------------------------------------------------
# Step 5: Print summary
# -----------------------------------------------------------------------
echo ""
echo "=== FINAL RESULTS ==="
find "$LOCAL_RESULTS" -name "summary.txt" -exec cat {} \; 2>/dev/null || \
    echo "No summary.txt found — check $LOCAL_RESULTS for build logs"

echo ""
echo "Workflow complete. Logs: $LOCAL_RESULTS"
