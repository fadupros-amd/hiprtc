#!/bin/bash
# Local orchestrator: transfer scripts to LUMI, run basilisk_main.exp on LUMI.
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

AWORKDIR="/tmp/basilisk_hip_${TIMESTAMP}"

# Password must be in environment
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
# Step 1: Create tmp dir on LUMI
# -----------------------------------------------------------------------
echo "--- Creating LUMI tmp dir ---"
lumi_run "mkdir -p ${LUMI_TMP}"

# -----------------------------------------------------------------------
# Step 2: SCP expect script, runner, and hip.c to LUMI
# -----------------------------------------------------------------------
echo "--- Copying scripts to LUMI ---"
lumi_scp \
    "$SCRIPT_DIR/basilisk_main.exp" \
    "$SCRIPT_DIR/basilisk_runner.sh" \
    "$SCRIPT_DIR/hip.c" \
    "${LUMI_USER}@${LUMI_HOST}:${LUMI_TMP}/"

# -----------------------------------------------------------------------
# Step 3: Run expect script on LUMI
# -----------------------------------------------------------------------
echo "--- Running basilisk_main.exp on LUMI ---"
lumi_run "
    export APWD='${ADASTRA_PASSWORD}'
    export AWORKDIR='${AWORKDIR}'
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
if ls "$LOCAL_RESULTS"/summary.txt 2>/dev/null; then
    cat "$LOCAL_RESULTS/summary.txt"
else
    # Try to find summary in subdirectory
    find "$LOCAL_RESULTS" -name "summary.txt" -exec cat {} \; 2>/dev/null || \
        echo "No summary.txt found — check $LOCAL_RESULTS for build logs"
fi

echo ""
echo "Workflow complete. Logs: $LOCAL_RESULTS"
