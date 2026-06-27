#!/bin/bash
#SBATCH --job-name=epo1030out
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=32
#SBATCH --time=120:00:00
#SBATCH --partition=genoa
#SBATCH --mail-type=END,FAIL
#SBATCH --mail-user=vatsal.sanjay@comphy-lab.org
#SBATCH --output=slurm-epo1030out-%j.out
#SBATCH --error=slurm-epo1030out-%j.err

# =============================================================================
# ElasticPinchOff - low-Oh Newtonian bubble pinch-off (LiquidOut) on Snellius.
#
#   Case c1030-out: Oh=1e-2, Oha=1e-4, De=0, Ec=0  -> purely Newtonian liquid.
#   Grid: MINlevel=8, MAXlevel=14.  tmax=20 (the run auto-stops at pinch-off
#   via the KE blow-up guard, so tmax is only an upper bound).
#
# ElasticPinchOff is an OpenMP code (NOT MPI): one Slurm task, many threads.
# Runs through the shared root runner runSimulation.sh, which compiles
# simulationCases/LiquidOutThinning.c with -fopenmp and runs it under
# OMP_NUM_THREADS=<cpus-per-task>.
#
# Usage:   sbatch runSnellius_c1030-out.sbatch
# Override: sbatch --export=ALL,BASILISK_REF=<ref> runSnellius_c1030-out.sbatch
# =============================================================================

set -euo pipefail

# --- Case definition ---------------------------------------------------------
CASE_NO=1030
CASE_MODE=out
OH=1e-2
OHA=1e-4
DE=0
EC=0
MINLEVEL=8
MAXLEVEL=14
TMAX=20
DTMAX=1e-5

SCRIPT_DIR="${SLURM_SUBMIT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
THREADS="${SLURM_CPUS_PER_TASK:-32}"
BASILISK_REF="${BASILISK_REF:-v2026-01-13}"
BASILISK_INSTALL_URL="https://raw.githubusercontent.com/comphy-lab/basilisk-C/main/reset_install_basilisk-ref-locked.sh"
cd "$SCRIPT_DIR"

echo "============================================="
echo "ElasticPinchOff - Snellius c${CASE_NO}-${CASE_MODE}"
echo "============================================="
echo "Started:   $(date)"
echo "Node:      $(hostname)"
echo "Job ID:    ${SLURM_JOB_ID:-local}"
echo "Threads:   ${THREADS}"
echo "Oh=${OH} Oha=${OHA} De=${DE} Ec=${EC} MINlevel=${MINLEVEL} MAXlevel=${MAXLEVEL} tmax=${TMAX}"
echo ""

echo "Loading modules..."
module purge
module load 2024
module load OpenMPI/5.0.3-GCC-13.3.0
echo ""

# Pin OpenMP threads to cores: the genoa node is shared, so keep threads from
# migrating across NUMA domains during the multi-day run.
export OMP_PROC_BIND=close
export OMP_PLACES=cores

# --- Ensure ref-locked Basilisk is available (install once on a fresh clone) --
if [[ ! -f "${SCRIPT_DIR}/.project_config" ]]; then
  echo "No .project_config found; installing ref-locked Basilisk (${BASILISK_REF})..."
  exec 9>"${SCRIPT_DIR}/.basilisk-install.lock"
  flock 9
  if [[ ! -f "${SCRIPT_DIR}/.project_config" ]]; then
    export TMPDIR="${SCRIPT_DIR}/.installtmp"
    mkdir -p "$TMPDIR"
    curl -fsSL "$BASILISK_INSTALL_URL" | bash -s -- --ref="$BASILISK_REF" --hard
    if [[ ! -x "${SCRIPT_DIR}/basilisk/src/qcc" ]]; then
      ( cd "${SCRIPT_DIR}/basilisk/src" && rm -f config && ln -s config.gcc config && { make -k >/dev/null 2>&1 || true; } && make )
    fi
    if [[ ! -f "${SCRIPT_DIR}/.project_config" ]]; then
      cat > "${SCRIPT_DIR}/.project_config" <<CFG
export BASILISK="${SCRIPT_DIR}/basilisk/src"
if [ ! -d "\$BASILISK" ]; then echo "Error: BASILISK not found" >&2; return 1 2>/dev/null || exit 1; fi
_PATH=":\$PATH:"; _PATH="\${_PATH//:\$BASILISK:/:}"; _PATH="\${_PATH#:}"; _PATH="\${_PATH%:}"
export PATH="\$BASILISK\${_PATH:+:\$_PATH}"; unset _PATH
hash -r 2>/dev/null || true
CFG
    fi
    rm -rf "${SCRIPT_DIR}/.installtmp"
  fi
  flock -u 9
fi

# --- Write the case parameter file -------------------------------------------
PARAM_DIR="${SCRIPT_DIR}/.snellius-params"
mkdir -p "$PARAM_DIR"
PARAM_FILE="${PARAM_DIR}/case_${CASE_NO}-${CASE_MODE}.params"
cat > "$PARAM_FILE" <<PARAMS
CaseNo=${CASE_NO}
MAXlevel=${MAXLEVEL}
MINlevel=${MINLEVEL}
Oh=${OH}
Oha=${OHA}
De=${DE}
Ec=${EC}
tmax=${TMAX}
dtmax=${DTMAX}
PARAMS
echo "Parameter file ${PARAM_FILE}:"
cat "$PARAM_FILE"
echo ""

# --- Run ---------------------------------------------------------------------
echo "Launching c${CASE_NO}-${CASE_MODE} (OpenMP, ${THREADS} threads)..."
rc=0
bash "${SCRIPT_DIR}/runSimulation.sh" "$PARAM_FILE" --mode "$CASE_MODE" --threads "$THREADS" || rc=$?

echo ""
echo "============================================="
echo "Finished:  $(date)  rc=${rc}"
echo "Output:    ${SCRIPT_DIR}/simulationCases/c${CASE_NO}-${CASE_MODE}/"
echo "Log:       ${SCRIPT_DIR}/simulationCases/c${CASE_NO}-${CASE_MODE}/c${CASE_NO}-log"
echo "============================================="
exit "$rc"
