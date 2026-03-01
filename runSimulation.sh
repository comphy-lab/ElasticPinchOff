#!/bin/bash
# runSimulation.sh
#
# Run a single ElasticPinchOff simulation from the repository root.
# The script creates simulationCases/<CaseNo>/, copies the parameter file and
# source file, compiles the selected case, and runs it.
#
# Usage:
#   bash runSimulation.sh [params_file] [--exec exec_code] [--mpi] [--CPUs N]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: bash runSimulation.sh [params_file] [--exec exec_code] [OPTIONS]

Arguments:
  params_file    Parameter file path (default: default.params)

Options:
  --exec FILE    C source in simulationCases/ (default: LiquidOutThinning.c)
  --mpi          Compile/run with MPI (qcc + mpicc wrapper, mpirun)
  --CPUs N       MPI process count for --mpi (default: 4)
  -h, --help     Show this help message
EOF
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

# Defaults
EXEC_CODE="LiquidOutThinning.c"
PARAM_FILE="default.params"
PARAM_FILE_SET=0
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
      if [[ $PARAM_FILE_SET -eq 0 ]]; then
        PARAM_FILE="$1"
        PARAM_FILE_SET=1
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

if [[ ! "$PARAM_FILE" = /* ]]; then
  PARAM_FILE="${SCRIPT_DIR}/${PARAM_FILE}"
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

if [[ $USE_MPI -eq 1 ]]; then
  if ! command -v mpicc >/dev/null 2>&1; then
    echo "ERROR: mpicc not found in PATH (required for --mpi)." >&2
    exit 1
  fi
  if ! command -v mpirun >/dev/null 2>&1; then
    echo "ERROR: mpirun not found in PATH (required for --mpi)." >&2
    exit 1
  fi
fi

if [[ ! -f "$PARAM_FILE" ]]; then
  echo "ERROR: Parameter file not found: $PARAM_FILE" >&2
  exit 1
fi

SRC_FILE_ORIG="${SCRIPT_DIR}/simulationCases/${EXEC_CODE}"
if [[ ! -f "$SRC_FILE_ORIG" ]]; then
  echo "ERROR: Source file not found: $SRC_FILE_ORIG" >&2
  exit 1
fi

CASE_NO="$(get_param_value "CaseNo" "$PARAM_FILE")"
if [[ -z "$CASE_NO" ]]; then
  echo "ERROR: CaseNo not found in parameter file: $PARAM_FILE" >&2
  exit 1
fi

if [[ ! "$CASE_NO" =~ ^[0-9]+$ ]]; then
  echo "ERROR: CaseNo must be numeric, got: $CASE_NO" >&2
  exit 1
fi

if [[ "$CASE_NO" -lt 1000 ]]; then
  echo "ERROR: CaseNo must be >= 1000 for consistent sorting, got: $CASE_NO" >&2
  exit 1
fi

CASE_DIR="${SCRIPT_DIR}/simulationCases/${CASE_NO}"
SRC_FILE_LOCAL="${EXEC_CODE}"
EXECUTABLE_NAME="${EXEC_CODE%.c}"
CASE_LOG_FILE="c${CASE_NO}-log"

echo "========================================="
echo "ElasticPinchOff - Single Case Runner"
echo "========================================="
echo "Source file: ${EXEC_CODE}"
echo "Parameter file: ${PARAM_FILE}"
echo "CaseNo: ${CASE_NO}"
echo "Case directory: ${CASE_DIR}"
if [[ $USE_MPI -eq 1 ]]; then
  echo "Run mode: MPI (np=${MPI_CPUS})"
else
  echo "Run mode: Serial"
fi
echo "Expected log file: ${CASE_LOG_FILE}"
echo "========================================="
echo ""

mkdir -p "$CASE_DIR"
cp "$PARAM_FILE" "$CASE_DIR/case.params"
cp "$SRC_FILE_ORIG" "$CASE_DIR/$SRC_FILE_LOCAL"

cd "$CASE_DIR"

echo "Compiling ${SRC_FILE_LOCAL} ..."
if [[ $USE_MPI -eq 1 ]]; then
  OS_NAME="$(uname -s)"
  if [[ "$OS_NAME" == "Darwin" ]]; then
    CC99='mpicc -std=c99' qcc -I../../src-local \
      -Wall -O2 -D_MPI=1 -disable-dimensions \
      "$SRC_FILE_LOCAL" -o "$EXECUTABLE_NAME" -lm
  elif [[ "$OS_NAME" == "Linux" ]]; then
    CC99='mpicc -std=c99 -D_GNU_SOURCE=1' qcc -I../../src-local \
      -Wall -O2 -disable-dimensions \
      "$SRC_FILE_LOCAL" -o "$EXECUTABLE_NAME" -lm
  else
    echo "ERROR: Unsupported OS for --mpi compile flags: ${OS_NAME}" >&2
    exit 1
  fi
else
  qcc -I../../src-local -Wall -O2 -disable-dimensions \
    "$SRC_FILE_LOCAL" -o "$EXECUTABLE_NAME" -lm
fi
echo "Compilation successful: $EXECUTABLE_NAME"
echo ""

if [[ -f "restart" ]]; then
  echo "Restart file found - simulation will resume from checkpoint."
fi

if [[ $USE_MPI -eq 1 ]]; then
  echo "Running: mpirun -np ${MPI_CPUS} ./${EXECUTABLE_NAME} case.params"
  if mpirun -np "$MPI_CPUS" ./"$EXECUTABLE_NAME" case.params; then
    EXIT_CODE=0
  else
    EXIT_CODE=$?
  fi
else
  echo "Running: ./${EXECUTABLE_NAME} case.params"
  if ./"$EXECUTABLE_NAME" case.params; then
    EXIT_CODE=0
  else
    EXIT_CODE=$?
  fi
fi

echo ""
if [[ $EXIT_CODE -eq 0 ]]; then
  echo "Simulation completed successfully."
  echo "Output location: simulationCases/${CASE_NO}/"
  if [[ -f "${CASE_LOG_FILE}" ]]; then
    echo "Log file: simulationCases/${CASE_NO}/${CASE_LOG_FILE}"
  fi
else
  echo "Simulation failed with exit code: $EXIT_CODE"
fi

exit "$EXIT_CODE"
