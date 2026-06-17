#!/bin/bash
# Runs on Adastra: find ROCm 5.4 and 7.2 modules, compile hip.c under each, report results.
# Usage: bash basilisk_runner.sh <workdir> <hip_c_path>
set -euo pipefail

WORKDIR=${1:-/tmp/basilisk_hip_$$}
HIP_C=${2:-$WORKDIR/hip.c}
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOGDIR=$WORKDIR/results_$TIMESTAMP
mkdir -p "$LOGDIR"

echo "=== Basilisk HIP compile test on Adastra ==="
echo "Workdir:   $WORKDIR"
echo "hip.c:     $HIP_C"
echo "Logdir:    $LOGDIR"
echo "Hostname:  $(hostname)"
echo "Date:      $TIMESTAMP"
echo ""

# -----------------------------------------------------------------------
# 0. Bootstrap the module system (needed in non-interactive SSH sessions)
# -----------------------------------------------------------------------
# Try standard locations for the Lmod/modules init script
for MODINIT in \
    /etc/profile.d/modules.sh \
    /opt/cray/pe/lmod/lmod/init/bash \
    /usr/share/lmod/lmod/init/bash \
    /usr/share/modules/init/bash; do
    if [[ -f "$MODINIT" ]]; then
        source "$MODINIT" 2>/dev/null && break
    fi
done

# Adastra-specific: also source the system profile to pick up MODULEPATH
[[ -f /etc/profile ]] && source /etc/profile 2>/dev/null || true
[[ -f "$HOME/.bashrc" ]] && source "$HOME/.bashrc" 2>/dev/null || true

echo "Module system init: $(type module 2>&1 | head -1)"
echo "MODULEPATH: ${MODULEPATH:-<empty>}"
echo ""

# -----------------------------------------------------------------------
# 1. Discover available ROCm modules for 5.4 and 7.2
# -----------------------------------------------------------------------
echo "--- Available ROCm modules ---"
module avail rocm 2>&1 | tee "$LOGDIR/module_avail.txt" || true

# Try to find module names matching 5.4.x and 7.2.x
ROCM54=$(module avail rocm 2>&1 | grep -oE 'rocm[/a-z0-9._-]*5\.4[^ ]*' | head -1 || true)
ROCM72=$(module avail rocm 2>&1 | grep -oE 'rocm[/a-z0-9._-]*7\.2[^ ]*' | head -1 || true)

echo ""
echo "Detected ROCm 5.4 module: ${ROCM54:-NOT FOUND}"
echo "Detected ROCm 7.2 module: ${ROCM72:-NOT FOUND}"
echo ""

# -----------------------------------------------------------------------
# 2. Compile function
# -----------------------------------------------------------------------
compile_hip_c() {
    local label=$1
    local rocm_mod=$2
    local logfile=$LOGDIR/build_${label}.log

    echo "--- Building: $label ($rocm_mod) ---"

    if [[ -z "$rocm_mod" ]]; then
        echo "RESULT: SKIP  label=$label  reason=module_not_found"
        echo "RESULT: SKIP  label=$label  reason=module_not_found" >> "$LOGDIR/summary.txt"
        return
    fi

    {
        echo "=== Build log: $label ==="
        echo "Module: $rocm_mod"
        echo "Date: $(date)"

        # Ensure module system is available in this subshell
        for MODINIT in /etc/profile.d/modules.sh /opt/cray/pe/lmod/lmod/init/bash /usr/share/lmod/lmod/init/bash; do
            [[ -f "$MODINIT" ]] && source "$MODINIT" 2>/dev/null && break
        done
        [[ -f /etc/profile ]] && source /etc/profile 2>/dev/null || true

        # Load just the ROCm module (no Cray PE needed for plain hipcc)
        module purge
        module load "$rocm_mod"

        echo "ROCM_PATH=$ROCM_PATH"
        echo "hipcc version: $(hipcc --version 2>&1 | head -3)"

        # Compile hip.c as HIP C++ (it's a .c file but uses HIP APIs)
        # We stub out the missing Basilisk headers via -D defines and empty includes.
        # The goal is to validate the HIP API surface compiles cleanly.
        local out=$LOGDIR/hip_${label}.o

        hipcc \
            --std=c++14 \
            --offload-arch=gfx90a \
            -DBASILISK_STUB=1 \
            -x hip \
            -I"$WORKDIR/stubs" \
            -c "$HIP_C" \
            -o "$out" \
            2>&1
        local rc=$?

        if [[ $rc -eq 0 ]]; then
            echo "Build: SUCCESS (exit 0)"
            echo "Output: $out ($(ls -lh "$out" | awk '{print $5}'))"
            echo "RESULT: PASS  label=$label  rocm=$rocm_mod"
            echo "RESULT: PASS  label=$label  rocm=$rocm_mod" >> "$LOGDIR/summary.txt"
        else
            echo "Build: FAILED (exit $rc)"
            echo "RESULT: FAIL  label=$label  rocm=$rocm_mod  exit=$rc"
            echo "RESULT: FAIL  label=$label  rocm=$rocm_mod  exit=$rc" >> "$LOGDIR/summary.txt"
        fi

    } 2>&1 | tee "$logfile"

    echo ""
}

# -----------------------------------------------------------------------
# 3. Write stub headers so hip.c preprocesses without Basilisk tree
# -----------------------------------------------------------------------
mkdir -p "$WORKDIR/stubs"

# Minimal stubs for Basilisk-internal headers included by hip.c
cat > "$WORKDIR/stubs/a32.h" << 'STUBEOF'
/* stub: a32.h */
#pragma once
typedef int  GPUData;
typedef enum { GPU_READ, GPU_WRITE } SyncMode;
extern struct { size_t current_size; int fragment_shader; } GPUContext;
STUBEOF

cat > "$WORKDIR/stubs/backend.h" << 'STUBEOF'
/* stub: backend.h */
#pragma once
typedef struct _Shader Shader;
#define IS_EXTERNAL_CONSTANT(g) 0
#define EXTERNAL_NAME(g) ((g)->name)
static inline char * str_append(char *s, const char *t){ return (char*)t; }
static inline char * gpu_errors(char *log, const char *src, void *u, const char *b){ return log; }
static struct { size_t current_size; int fragment_shader; } GPUContext;
STUBEOF

cat > "$WORKDIR/stubs/symbols.h" << 'STUBEOF'
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

echo "Stub headers written to $WORKDIR/stubs/"
echo ""

# -----------------------------------------------------------------------
# 4. Run builds
# -----------------------------------------------------------------------
touch "$LOGDIR/summary.txt"
compile_hip_c "rocm54" "$ROCM54"
compile_hip_c "rocm72" "$ROCM72"

# -----------------------------------------------------------------------
# 5. Summary
# -----------------------------------------------------------------------
echo ""
echo "=== SUMMARY ==="
cat "$LOGDIR/summary.txt"
echo ""
echo "Full logs in: $LOGDIR"
echo "BASILISK_RUNNER_DONE"
