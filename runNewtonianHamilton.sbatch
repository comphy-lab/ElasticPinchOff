#!/bin/bash
#SBATCH --job-name=elasticNewtonian
#SBATCH --array=0-2%3
#SBATCH -N 1
#SBATCH -n 1
#SBATCH -c 40
#SBATCH --mem=80G
#SBATCH --time=3-00:00:00
#SBATCH --gres=tmp:35G
#SBATCH -p shared
#SBATCH --output=slurm-%A_%a.out
#SBATCH --error=slurm-%A_%a.err

# Run the three Newtonian ElasticPinchOff cases on Hamilton.
#
# Usage:
#   sbatch runNewtonianHamilton.sbatch
#
# This is a Slurm job array on Hamilton's shared partition: each array task runs
# exactly one case with one OpenMP process. Slurm owns CPU placement for every
# case, avoiding accidental contention between background subprocesses inside a
# single batch step.
#
# Defaults:
#   task 0: c1020-in, Oh=0,    Oha=0,    De=0, Ec=0
#   task 1: c1021-in, Oh=1e-2, Oha=1e-4, De=0, Ec=0
#   task 2: c1022-in, Oh=1e0,  Oha=1e-2, De=0, Ec=0
#
# Optional overrides:
#   sbatch --export=ALL,CASE_MODE=out runNewtonianHamilton.sbatch
#   sbatch --export=ALL,OMP_THREADS=32 runNewtonianHamilton.sbatch

set -euo pipefail

SCRIPT_DIR="${SLURM_SUBMIT_DIR:-$(pwd)}"
CASE_MODE="${CASE_MODE:-in}"
CASE_START="${CASE_START:-1020}"
OMP_THREADS="${OMP_THREADS:-${SLURM_CPUS_PER_TASK:-40}}"
TMAX="${TMAX:-60}"
BASILISK_REF="${BASILISK_REF:-v2026-01-13}"
BASILISK_INSTALL_URL="https://raw.githubusercontent.com/comphy-lab/basilisk-C/main/reset_install_basilisk-ref-locked.sh"

OH_VALUES=(0 1e-2 1e0)
OHA_VALUES=(0 1e-4 1e-2)
DE_VALUE=0
EC_VALUE=0

set_param_in_file() {
  local key="$1"
  local value="$2"
  local file="$3"

  if grep -q "^${key}=" "$file"; then
    sed -i'.bak' "s|^${key}=.*|${key}=${value}|" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >> "$file"
  fi
  rm -f "${file}.bak"
}

if [[ "$CASE_MODE" != "in" && "$CASE_MODE" != "out" ]]; then
  echo "ERROR: CASE_MODE must be 'in' or 'out', got '${CASE_MODE}'." >&2
  exit 1
fi

if [[ ${#OH_VALUES[@]} -ne ${#OHA_VALUES[@]} ]]; then
  echo "ERROR: OH_VALUES and OHA_VALUES must have matching lengths." >&2
  exit 1
fi

TASK_ID="${SLURM_ARRAY_TASK_ID:-${CASE_INDEX:-0}}"
if [[ ! "$TASK_ID" =~ ^[0-9]+$ ]] || [[ "$TASK_ID" -ge ${#OH_VALUES[@]} ]]; then
  echo "ERROR: task index must be 0..$((${#OH_VALUES[@]} - 1)), got '${TASK_ID}'." >&2
  exit 1
fi

case_no=$((CASE_START + TASK_ID))
case_label="c${case_no}-${CASE_MODE}"
oh_value="${OH_VALUES[$TASK_ID]}"
oha_value="${OHA_VALUES[$TASK_ID]}"

if [[ ! "$SCRIPT_DIR" =~ ^/nobackup/ ]]; then
  echo "WARNING: Running from $SCRIPT_DIR"
  echo "         Hamilton jobs should run from /nobackup/\$USER/."
  echo ""
fi

cd "$SCRIPT_DIR"

echo "============================================="
echo "ElasticPinchOff - Newtonian Hamilton case"
echo "============================================="
echo "Started: $(date)"
echo "Node: $(hostname)"
echo "Working directory: $(pwd)"
echo "Job ID: ${SLURM_JOB_ID:-unknown}"
echo "Array task: ${TASK_ID}"
echo "Case: ${case_label}"
echo "Mode: ${CASE_MODE}"
echo "Oh: ${oh_value}"
echo "Oha: ${oha_value}"
echo "De: ${DE_VALUE}"
echo "Ec: ${EC_VALUE}"
echo "Threads: ${OMP_THREADS}"
echo "tmax: ${TMAX}"
echo "Basilisk ref: ${BASILISK_REF}"
echo "TMPDIR: ${TMPDIR:-not set}"
echo ""

echo "Loading modules..."
module purge
module load gcc
echo "Modules loaded."
echo ""

if ! command -v curl >/dev/null 2>&1; then
  echo "ERROR: curl not found; required for Basilisk install." >&2
  exit 1
fi

echo "Installing or refreshing Basilisk (${BASILISK_REF})..."
LOCK_FILE="${SCRIPT_DIR}/basilisk/.comphy-lock"
LOCK_REF=""
if [[ -f "$LOCK_FILE" ]]; then
  LOCK_REF="$(awk -F= '$1=="ref"{print $2; exit}' "$LOCK_FILE" 2>/dev/null || true)"
fi
if [[ ! -f "$LOCK_FILE" || "$LOCK_REF" != "$BASILISK_REF" ]]; then
  curl -fsSL "$BASILISK_INSTALL_URL" | bash -s -- --ref="$BASILISK_REF" --hard
else
  curl -fsSL "$BASILISK_INSTALL_URL" | bash -s -- --ref="$BASILISK_REF"
fi

if [[ -f "${SCRIPT_DIR}/.project_config" ]]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/.project_config"
else
  echo "ERROR: .project_config not found after Basilisk install." >&2
  exit 1
fi

if ! command -v qcc >/dev/null 2>&1; then
  echo "ERROR: qcc not found after sourcing .project_config." >&2
  exit 1
fi
echo "qcc: $(command -v qcc)"
echo ""

BASE_CONFIG="${SCRIPT_DIR}/default.params"
if [[ ! -f "$BASE_CONFIG" ]]; then
  echo "ERROR: default.params not found at $BASE_CONFIG" >&2
  exit 1
fi

RUN_SCRIPT="${SCRIPT_DIR}/runSimulation.sh"
if [[ ! -f "$RUN_SCRIPT" ]]; then
  echo "ERROR: runSimulation.sh not found at $RUN_SCRIPT" >&2
  exit 1
fi

PARAM_DIR="${SCRIPT_DIR}/.hamilton-newtonian-${SLURM_ARRAY_JOB_ID:-${SLURM_JOB_ID:-manual}}"
LOG_DIR="${PARAM_DIR}/logs"
param_file="${PARAM_DIR}/case_${case_no}.params"
mkdir -p "$LOG_DIR"

cp "$BASE_CONFIG" "$param_file"
set_param_in_file "CaseNo" "$case_no" "$param_file"
set_param_in_file "Oh" "$oh_value" "$param_file"
set_param_in_file "Oha" "$oha_value" "$param_file"
set_param_in_file "De" "$DE_VALUE" "$param_file"
set_param_in_file "Ec" "$EC_VALUE" "$param_file"
set_param_in_file "tmax" "$TMAX" "$param_file"

echo "Prepared ${case_label}:"
echo "  params: ${param_file}"
echo "  Oh=${oh_value}, Oha=${oha_value}, De=${DE_VALUE}, Ec=${EC_VALUE}, tmax=${TMAX}"
echo ""

echo "Launching ${case_label} with Slurm-managed CPU binding..."
srun --exclusive --ntasks=1 --cpus-per-task="$OMP_THREADS" \
  bash "$RUN_SCRIPT" "$param_file" --mode "$CASE_MODE" --threads "$OMP_THREADS" \
  >"${LOG_DIR}/${case_label}.out" 2>"${LOG_DIR}/${case_label}.err"

echo ""
echo "============================================="
echo "Newtonian Hamilton case complete"
echo "============================================="
echo "Finished: $(date)"
echo "Case: ${case_label}"
echo "Case output root: ${SCRIPT_DIR}/simulationCases/${case_label}"
echo "Case run log: ${LOG_DIR}/${case_label}.out"
echo "Case run err: ${LOG_DIR}/${case_label}.err"
echo "============================================="
