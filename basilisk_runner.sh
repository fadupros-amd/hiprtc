#!/bin/bash
# Runs on Adastra: compile hip.c under ROCm 5.5.1 and 7.2.0 directly (no modules needed).
# ROCm installations are in /opt/rocm-X.Y.Z/ — we invoke hipcc directly.
# Usage: bash basilisk_runner.sh <workdir> <hip_c_path>

WORKDIR=${1:-/tmp/basilisk_hip_$$}
HIP_C_SRC=${2:-$WORKDIR/hip.c}
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOGDIR=$WORKDIR/results_$TIMESTAMP
mkdir -p "$LOGDIR"

# Place hip.c at src/grid/hip/hip.c so relative includes resolve inside WORKDIR:
#   #include "../../ast/symbols.h"  -> src/ast/symbols.h  (2 levels up from src/grid/hip/)
#   #include "../gpu/backend.h"     -> src/grid/gpu/backend.h
#   #include "a32.h"                -> src/grid/hip/a32.h
mkdir -p "$WORKDIR/src/grid/hip" "$WORKDIR/src/grid/gpu" "$WORKDIR/src/ast"
cp "$HIP_C_SRC" "$WORKDIR/src/grid/hip/hip.c"
HIP_C="$WORKDIR/src/grid/hip/hip.c"

echo "=== Basilisk HIP compile test on Adastra ==="
echo "Workdir:   $WORKDIR"
echo "hip.c:     $HIP_C"
echo "Logdir:    $LOGDIR"
echo "Hostname:  $(hostname)"
echo "Date:      $TIMESTAMP"
echo ""

# Note: ROCm 5.4 is not installed on Adastra — using 5.5.1 (closest 5.x) and 7.2.0
ROCM_VERSIONS=(
    "rocm551:/opt/rocm-5.5.1"
    "rocm720:/opt/rocm-7.2.0"
)

# -----------------------------------------------------------------------
# Write stub headers so hip.c preprocesses without the full Basilisk tree
# -----------------------------------------------------------------------
mkdir -p "$WORKDIR/stubs"

# Stubs placed to match relative includes in hip.c (now at src/grid/hip/hip.c):
#   "a32.h"               -> src/grid/hip/a32.h
#   "../gpu/backend.h"    -> src/grid/gpu/backend.h
#   "../../ast/symbols.h" -> src/ast/symbols.h

cat > "$WORKDIR/src/grid/hip/a32.h" << 'STUBEOF'
/* stub: a32.h */
#pragma once
typedef int  GPUData;
typedef enum { GPU_READ, GPU_WRITE } SyncMode;
static struct { size_t current_size; int fragment_shader; } GPUContext;
STUBEOF

cat > "$WORKDIR/src/grid/gpu/backend.h" << 'STUBEOF'
/* stub: backend.h */
#pragma once
typedef struct _Shader Shader;
#define IS_EXTERNAL_CONSTANT(g) 0
#define EXTERNAL_NAME(g) ((g)->name)
static inline char * str_append(char *s, const char *t){ return (char*)t; }
static inline char * gpu_errors(char *log, const char *src, void *u, const char *b){ return log; }
STUBEOF

cat > "$WORKDIR/src/ast/symbols.h" << 'STUBEOF'
/* stub: symbols.h */
#pragma once
#define sym_root  100
#define sym_INT   (sym_root+10)
#define sym_LONG  (sym_root+11)
#define sym_FLOAT (sym_root+12)
#define sym_DOUBLE (sym_root+13)
#define sym_BOOL  (sym_root+14)
#define sym_function_declaration (sym_root+20)
#define sym_function_definition  (sym_root+21)
STUBEOF

echo "Stub headers written:"
echo "  $WORKDIR/src/grid/hip/a32.h"
echo "  $WORKDIR/src/grid/gpu/backend.h"
echo "  $WORKDIR/src/ast/symbols.h"
echo ""

# -----------------------------------------------------------------------
# Compile function — uses hipcc directly from ROCM_PATH (no modules)
# -----------------------------------------------------------------------
touch "$LOGDIR/summary.txt"

compile_hip_c() {
    local label=$1
    local rocm_path=$2
    local logfile=$LOGDIR/build_${label}.log
    local hipcc="$rocm_path/bin/hipcc"

    echo "--- Building: $label ($rocm_path) ---"

    if [[ ! -x "$hipcc" ]]; then
        echo "RESULT: SKIP  label=$label  reason=hipcc_not_found_at_$rocm_path"
        echo "RESULT: SKIP  label=$label  reason=hipcc_not_found_at_$rocm_path" >> "$LOGDIR/summary.txt"
        return
    fi

    {
        echo "=== Build log: $label ==="
        echo "ROCm path: $rocm_path"
        echo "hipcc:     $hipcc"
        echo "Date: $(date)"
        echo ""
        echo "hipcc version:"
        "$hipcc" --version 2>&1 | head -5
        echo ""

        local out=$LOGDIR/hip_${label}.o

        "$hipcc" \
            --std=c++14 \
            --offload-arch=gfx90a \
            -x hip \
            -I"$rocm_path/include" \
            -c "$HIP_C" \
            -o "$out" \
            2>&1
        local rc=$?

        if [[ $rc -eq 0 ]]; then
            local sz
            sz=$(ls -lh "$out" 2>/dev/null | awk '{print $5}')
            echo ""
            echo "Build: SUCCESS (exit 0) — output $sz"
            echo "RESULT: PASS  label=$label  rocm=$rocm_path"
            echo "RESULT: PASS  label=$label  rocm=$rocm_path" >> "$LOGDIR/summary.txt"
        else
            echo ""
            echo "Build: FAILED (exit $rc)"
            echo "RESULT: FAIL  label=$label  rocm=$rocm_path  exit=$rc"
            echo "RESULT: FAIL  label=$label  rocm=$rocm_path  exit=$rc" >> "$LOGDIR/summary.txt"
        fi

    } 2>&1 | tee "$logfile"

    echo ""
}

# -----------------------------------------------------------------------
# Run builds for each ROCm version
# -----------------------------------------------------------------------
for entry in "${ROCM_VERSIONS[@]}"; do
    label="${entry%%:*}"
    rocm_path="${entry##*:}"
    compile_hip_c "$label" "$rocm_path"
done

# -----------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------
echo "=== SUMMARY ==="
cat "$LOGDIR/summary.txt"
echo ""
echo "Full logs in: $LOGDIR"
echo "BASILISK_RUNNER_DONE"
