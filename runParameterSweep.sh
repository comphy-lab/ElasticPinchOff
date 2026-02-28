#!/bin/bash
# runParameterSweep.sh
#
# Run an ElasticPinchOff parameter sweep from the repository root.
# The script reads SWEEP_* variables from a sweep config file, generates
# case-specific parameter files with incrementing CaseNo, then runs each case
# sequentially using runSimulation.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: bash runParameterSweep.sh [sweep_file] [--exec exec_code] [OPTIONS]

Arguments:
  sweep_file     Sweep config path (default: sweep.params)

Options:
  --exec FILE    C source in simulationCases/ (default: LiquidOutThinning.c)
  --mpi          Compile/run each case with MPI via runSimulation.sh
  --CPUs N       MPI process count for --mpi (default: 4)
  -n, --dry-run  Show generated parameter combinations only
  -v, --verbose  Print expanded per-case parameter details
  -h, --help     Show this help message
EOF
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

get_param_value() {
  local key="$1"
  local file="$2"
  awk -F '=' -v key="$key" '
    /^[[:space:]]*#/ { next }
    {
      k = $1
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
      if (k == key) {
        v = $2
        sub(/[[:space:]]*#.*/, "", v)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
        print v
        exit
      }
    }
  ' "$file"
}

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

parse_sweep_variables() {
  local file="$1"
  local raw_key raw_value key value

  SWEEP_VARS=()
  SWEEP_VALUES_RAW=()

  while IFS='=' read -r raw_key raw_value || [[ -n "${raw_key:-}" ]]; do
    key="$(trim "${raw_key:-}")"
    [[ -z "$key" ]] && continue
    [[ "$key" == \#* ]] && continue

    if [[ "$key" =~ ^SWEEP_([A-Za-z0-9_]+)$ ]]; then
      value="${raw_value:-}"
      value="${value%%#*}"
      value="$(trim "$value")"
      if [[ -z "$value" ]]; then
        echo "ERROR: Empty value list for ${key} in $file" >&2
        exit 1
      fi
      SWEEP_VARS+=("${BASH_REMATCH[1]}")
      SWEEP_VALUES_RAW+=("$value")
    fi
  done < "$file"

  if [[ ${#SWEEP_VARS[@]} -eq 0 ]]; then
    echo "ERROR: No SWEEP_* variables found in $file" >&2
    exit 1
  fi
}

generate_combinations() {
  local depth="$1"
  shift || true
  local current_values=("$@")

  if [[ "$depth" -eq "${#SWEEP_VARS[@]}" ]]; then
    local case_no="$CURRENT_CASE_NO"
    local case_file="${TEMP_DIR}/case_$(printf '%04d' "$case_no").params"
    local i

    cp "$BASE_CONFIG" "$case_file"
    set_param_in_file "CaseNo" "$case_no" "$case_file"

    for i in "${!SWEEP_VARS[@]}"; do
      set_param_in_file "${SWEEP_VARS[$i]}" "${current_values[$i]}" "$case_file"
    done

    PARAM_FILES+=("$case_file")
    ((COMBINATION_COUNT += 1))
    ((CURRENT_CASE_NO += 1))

    if [[ $DRY_RUN -eq 1 || $VERBOSE -eq 1 ]]; then
      echo "Case ${case_no}:"
      for i in "${!SWEEP_VARS[@]}"; do
        echo "  ${SWEEP_VARS[$i]}=${current_values[$i]}"
      done
      echo ""
    fi
    return
  fi

  local values="${SWEEP_VALUES_RAW[$depth]}"
  local value_array=()
  local value trimmed_value

  IFS=',' read -r -a value_array <<< "$values"
  for value in "${value_array[@]}"; do
    trimmed_value="$(trim "$value")"
    [[ -z "$trimmed_value" ]] && continue
    if [[ ${#current_values[@]} -gt 0 ]]; then
      generate_combinations $((depth + 1)) "${current_values[@]}" "$trimmed_value"
    else
      generate_combinations $((depth + 1)) "$trimmed_value"
    fi
  done
}

# Defaults
EXEC_CODE="LiquidOutThinning.c"
SWEEP_FILE="sweep.params"
SWEEP_FILE_SET=0
DRY_RUN=0
VERBOSE=0
USE_MPI=0
MPI_CPUS=4

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --exec)
      if [[ -z "${2:-}" ]]; then
        echo "ERROR: --exec requires a file name." >&2
        usage
        exit 1
      fi
      EXEC_CODE="$2"
      shift 2
      ;;
    --exec=*)
      EXEC_CODE="${1#*=}"
      shift
      ;;
    --mpi)
      USE_MPI=1
      shift
      ;;
    --CPUs|--cpus)
      if [[ -z "${2:-}" ]]; then
        echo "ERROR: $1 requires a positive integer value." >&2
        usage
        exit 1
      fi
      MPI_CPUS="$2"
      shift 2
      ;;
    --CPUs=*|--cpus=*)
      MPI_CPUS="${1#*=}"
      shift
      ;;
    -n|--dry-run)
      DRY_RUN=1
      shift
      ;;
    -v|--verbose)
      VERBOSE=1
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "ERROR: Unknown option: $1" >&2
      usage
      exit 1
      ;;
    *)
      if [[ $SWEEP_FILE_SET -eq 0 ]]; then
        SWEEP_FILE="$1"
        SWEEP_FILE_SET=1
        shift
      else
        echo "ERROR: Unexpected argument: $1" >&2
        usage
        exit 1
      fi
      ;;
  esac
done

if [[ $# -gt 0 ]]; then
  echo "ERROR: Unexpected trailing arguments: $*" >&2
  usage
  exit 1
fi

if [[ ! "$MPI_CPUS" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: --CPUs must be a positive integer, got: $MPI_CPUS" >&2
  exit 1
fi

if [[ "$EXEC_CODE" != *.c ]]; then
  EXEC_CODE="${EXEC_CODE}.c"
fi

if [[ ! "$SWEEP_FILE" = /* ]]; then
  SWEEP_FILE="${SCRIPT_DIR}/${SWEEP_FILE}"
fi

if [[ ! -f "$SWEEP_FILE" ]]; then
  echo "ERROR: Sweep file not found: $SWEEP_FILE" >&2
  exit 1
fi

if [[ -f "${SCRIPT_DIR}/.project_config" ]]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/.project_config"
fi

if ! command -v qcc >/dev/null 2>&1; then
  echo "ERROR: qcc not found in PATH." >&2
  echo "Hint: source your Basilisk environment or provide .project_config." >&2
  exit 1
fi

RUN_SIM_SCRIPT="${SCRIPT_DIR}/runSimulation.sh"
if [[ ! -f "$RUN_SIM_SCRIPT" ]]; then
  echo "ERROR: runSimulation.sh not found at ${RUN_SIM_SCRIPT}" >&2
  exit 1
fi

SRC_FILE_ORIG="${SCRIPT_DIR}/simulationCases/${EXEC_CODE}"
if [[ ! -f "$SRC_FILE_ORIG" ]]; then
  echo "ERROR: Source file not found: $SRC_FILE_ORIG" >&2
  exit 1
fi

CONFIG_DIR="$(cd "$(dirname "$SWEEP_FILE")" && pwd)"

# shellcheck disable=SC1090
source "$SWEEP_FILE"

BASE_CONFIG="${BASE_CONFIG:-default.params}"
CASE_START="${CASE_START:-1000}"

if [[ "$BASE_CONFIG" != /* ]]; then
  BASE_CONFIG="${CONFIG_DIR}/${BASE_CONFIG}"
fi

if [[ ! -f "$BASE_CONFIG" ]]; then
  echo "ERROR: BASE_CONFIG file not found: $BASE_CONFIG" >&2
  exit 1
fi

if [[ ! "$CASE_START" =~ ^[0-9]+$ ]]; then
  echo "ERROR: CASE_START must be numeric, got: $CASE_START" >&2
  exit 1
fi

if [[ "$CASE_START" -lt 1000 ]]; then
  echo "ERROR: CASE_START must be >= 1000 for consistent sorting, got: $CASE_START" >&2
  exit 1
fi

if [[ -n "${CASE_END:-}" ]] && [[ ! "$CASE_END" =~ ^[0-9]+$ ]]; then
  echo "ERROR: CASE_END must be numeric when provided, got: $CASE_END" >&2
  exit 1
fi

if [[ -n "${CASE_END:-}" ]] && [[ "$CASE_END" -lt 1000 ]]; then
  echo "ERROR: CASE_END must be >= 1000 when provided, got: $CASE_END" >&2
  exit 1
fi

parse_sweep_variables "$SWEEP_FILE"

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/elastic-sweep.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT

PARAM_FILES=()
COMBINATION_COUNT=0
CURRENT_CASE_NO="$CASE_START"
generate_combinations 0

if [[ "$COMBINATION_COUNT" -le 0 ]]; then
  echo "ERROR: No parameter combinations generated." >&2
  exit 1
fi

if [[ -n "${CASE_END:-}" ]]; then
  EXPECTED_COUNT=$((CASE_END - CASE_START + 1))
  if [[ "$EXPECTED_COUNT" -ne "$COMBINATION_COUNT" ]]; then
    echo "ERROR: CASE_START/CASE_END imply ${EXPECTED_COUNT} cases, but generated ${COMBINATION_COUNT} combinations." >&2
    exit 1
  fi
else
  CASE_END=$((CASE_START + COMBINATION_COUNT - 1))
fi

echo "========================================="
echo "ElasticPinchOff - Parameter Sweep"
echo "========================================="
echo "Sweep file: ${SWEEP_FILE}"
echo "Source file: ${EXEC_CODE}"
echo "Base config: ${BASE_CONFIG}"
echo "Sweep variables: ${#SWEEP_VARS[@]}"
echo "Cases: ${CASE_START}..${CASE_END} (${COMBINATION_COUNT})"
if [[ $USE_MPI -eq 1 ]]; then
  echo "Run mode: MPI (np=${MPI_CPUS})"
else
  echo "Run mode: Serial"
fi
if [[ $DRY_RUN -eq 1 ]]; then
  echo "Mode: Dry run"
fi
echo "========================================="
echo ""

if [[ $DRY_RUN -eq 1 ]]; then
  echo "Dry run complete. No simulations executed."
  exit 0
fi

SUCCESSFUL=0
FAILED=0

for param_file in "${PARAM_FILES[@]}"; do
  case_no="$(get_param_value "CaseNo" "$param_file")"
  ec_value="$(get_param_value "Ec" "$param_file")"
  de_value="$(get_param_value "De" "$param_file")"
  tmax_value="$(get_param_value "tmax" "$param_file")"

  echo "-----------------------------------------"
  echo "Running Case ${case_no}"
  echo "Ec=${ec_value:-NA}, De=${de_value:-NA}, tmax=${tmax_value:-NA}"
  echo "Expected log file: c${case_no}-log"
  echo "-----------------------------------------"

  run_cmd=(bash "$RUN_SIM_SCRIPT" "$param_file" --exec "$EXEC_CODE")
  if [[ $USE_MPI -eq 1 ]]; then
    run_cmd+=(--mpi --CPUs "$MPI_CPUS")
  fi

  if "${run_cmd[@]}"; then
    ((SUCCESSFUL += 1))
  else
    ((FAILED += 1))
    echo "ERROR: Case ${case_no} failed." >&2
  fi
  echo ""
done

echo "========================================="
echo "Parameter Sweep Complete"
echo "========================================="
echo "Total cases: ${COMBINATION_COUNT}"
echo "Successful: ${SUCCESSFUL}"
echo "Failed: ${FAILED}"
echo "Outputs: simulationCases/"
echo "========================================="

if [[ "$FAILED" -gt 0 ]]; then
  exit 1
fi

exit 0
