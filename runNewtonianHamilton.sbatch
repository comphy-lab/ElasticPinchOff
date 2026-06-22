#!/bin/bash
#SBATCH --job-name=elasticNewtonian
#SBATCH -N 1
#SBATCH -n 3
#SBATCH -c 40
#SBATCH --mem=240G
#SBATCH --time=3-00:00:00
#SBATCH --gres=tmp:100G
#SBATCH -p multi
#SBATCH --output=slurm-%j.out
#SBATCH --error=slurm-%j.err

# Run the three Newtonian ElasticPinchOff cases on Hamilton.
#
# Usage:
#   sbatch runNewtonianHamilton.sbatch
#
# Defaults:
#   mode=in, cases c1020-in..c1022-in, 3 concurrent OpenMP runs,
#   40 threads per case on one 128-core multi node.
#
# Optional overrides:
#   sbatch --export=ALL,CASE_MODE=out runNewtonianHamilton.sbatch
#   sbatch --export=ALL,OMP_THREADS=32,MAX_PARALLEL=3 runNewtonianHamilton.sbatch

set -euo pipefail

SCRIPT_DIR="${SLURM_SUBMIT_DIR:-$(pwd)}"
CASE_MODE="${CASE_MODE:-in}"
CASE_START="${CASE_START:-1020}"
OMP_THREADS="${OMP_THREADS:-${SLURM_CPUS_PER_TASK:-40}}"
MAX_PARALLEL="${MAX_PARALLEL:-3}"
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

wait_for_case() {
  local idx="$1"
  local pid="${RUN_PIDS[$idx]}"
  local label="${RUN_LABELS[$idx]}"

  if wait "$pid"; then
    ((SUCCESSFUL += 1))
    echo "${label} completed."
  else
    ((FAILED += 1))
    echo "ERROR: ${label} failed." >&2
  fi

  unset 'RUN_PIDS[idx]'
  unset 'RUN_LABELS[idx]'
  RUN_PIDS=("${RUN_PIDS[@]}")
  RUN_LABELS=("${RUN_LABELS[@]}")
}

wait_for_one_active_case() {
  wait_for_case 0
}

if [[ "$CASE_MODE" != "in" && "$CASE_MODE" != "out" ]]; then
  echo "ERROR: CASE_MODE must be 'in' or 'out', got '${CASE_MODE}'." >&2
  exit 1
fi

if [[ ${#OH_VALUES[@]} -ne ${#OHA_VALUES[@]} ]]; then
  echo "ERROR: OH_VALUES and OHA_VALUES must have matching lengths." >&2
  exit 1
fi

if [[ ! "$SCRIPT_DIR" =~ ^/nobackup/ ]]; then
  echo "WARNING: Running from $SCRIPT_DIR"
  echo "         Hamilton jobs should run from /nobackup/\$USER/."
  echo ""
fi

cd "$SCRIPT_DIR"

echo "============================================="
echo "ElasticPinchOff - Newtonian Hamilton cases"
echo "============================================="
echo "Started: $(date)"
echo "Node: $(hostname)"
echo "Working directory: $(pwd)"
echo "Job ID: ${SLURM_JOB_ID:-unknown}"
echo "Mode: ${CASE_MODE}"
echo "Cases: ${#OH_VALUES[@]}"
echo "Threads per case: ${OMP_THREADS}"
echo "Max concurrent cases: ${MAX_PARALLEL}"
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

PARAM_DIR="${SCRIPT_DIR}/.hamilton-newtonian-${SLURM_JOB_ID:-manual}"
LOG_DIR="${PARAM_DIR}/logs"
mkdir -p "$LOG_DIR"

SUCCESSFUL=0
FAILED=0
RUN_PIDS=()
RUN_LABELS=()

echo "Prepared cases:"
for i in "${!OH_VALUES[@]}"; do
  case_no=$((CASE_START + i))
  param_file="${PARAM_DIR}/case_${case_no}.params"
  cp "$BASE_CONFIG" "$param_file"
  set_param_in_file "CaseNo" "$case_no" "$param_file"
  set_param_in_file "Oh" "${OH_VALUES[$i]}" "$param_file"
  set_param_in_file "Oha" "${OHA_VALUES[$i]}" "$param_file"
  set_param_in_file "De" "$DE_VALUE" "$param_file"
  set_param_in_file "Ec" "$EC_VALUE" "$param_file"
  set_param_in_file "tmax" "$TMAX" "$param_file"

  echo "  c${case_no}-${CASE_MODE}: Oh=${OH_VALUES[$i]}, Oha=${OHA_VALUES[$i]}, De=${DE_VALUE}, Ec=${EC_VALUE}, tmax=${TMAX}"
done
echo ""

for i in "${!OH_VALUES[@]}"; do
  case_no=$((CASE_START + i))
  param_file="${PARAM_DIR}/case_${case_no}.params"
  label="c${case_no}-${CASE_MODE}"

  echo "Launching ${label} at $(date)"
  (
    bash "$RUN_SCRIPT" "$param_file" --mode "$CASE_MODE" --threads "$OMP_THREADS"
  ) >"${LOG_DIR}/${label}.out" 2>"${LOG_DIR}/${label}.err" &

  RUN_PIDS+=("$!")
  RUN_LABELS+=("$label")

  if [[ ${#RUN_PIDS[@]} -ge $MAX_PARALLEL ]]; then
    wait_for_one_active_case
  fi
done

while [[ ${#RUN_PIDS[@]} -gt 0 ]]; do
  wait_for_one_active_case
done

echo ""
echo "============================================="
echo "Newtonian Hamilton cases complete"
echo "============================================="
echo "Finished: $(date)"
echo "Successful: ${SUCCESSFUL}"
echo "Failed: ${FAILED}"
echo "Case output root: ${SCRIPT_DIR}/simulationCases"
echo "Per-case run logs: ${LOG_DIR}"
echo "============================================="

if [[ "$FAILED" -gt 0 ]]; then
  exit 1
fi
