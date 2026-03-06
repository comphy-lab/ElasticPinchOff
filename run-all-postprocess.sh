#!/usr/bin/env bash
# run-all-postprocess.sh
# Batch post-processing: generates videos for all case directories in simulationCases/
# Usage: bash run-all-postprocess.sh [--cpus N] [--dry-run]
#
# Processes ONE case at a time (sequential), but each case uses --cpus workers
# for parallel frame rendering. This avoids overloading the machine.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIM_DIR="$REPO_ROOT/simulationCases"
PP_SCRIPT="$REPO_ROOT/postProcess/Video-generic.py"
LOG_DIR="$REPO_ROOT/postprocess-logs"

# Defaults
CPUS=4
DRY_RUN=false

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cpus) CPUS="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# Environment setup
source ~/miniconda3/etc/profile.d/conda.sh
conda activate default
export BASILISK="/home/vatsal/CMP-codes/basilisk/src"
export PATH="$BASILISK:$PATH"

mkdir -p "$LOG_DIR"

echo "=================================================="
echo "Batch Post-Processing"
echo "Repo:    $REPO_ROOT"
echo "CPUs:    $CPUS per case (sequential case processing)"
echo "Started: $(date)"
echo "=================================================="

TOTAL=0
DONE=0
FAILED=0
SKIPPED=0

# Count eligible cases
for case_dir in "$SIM_DIR"/c*-{in,out}; do
  [[ -d "$case_dir" ]] || continue
  TOTAL=$((TOTAL + 1))
done

echo "Found $TOTAL case directories"
echo ""

for case_dir in "$SIM_DIR"/c*-{in,out}; do
  [[ -d "$case_dir" ]] || continue
  
  case_name=$(basename "$case_dir")
  snap_count=$(ls "$case_dir/intermediate/snapshot-"* 2>/dev/null | wc -l)
  
  if [[ "$snap_count" -eq 0 ]]; then
    echo "[$case_name] SKIP — no snapshots"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi
  
  # Check if video already exists
  if [[ -f "$case_dir/video-film-generic.mp4" ]]; then
    echo "[$case_name] SKIP — video already exists ($snap_count snapshots)"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi
  
  echo "[$case_name] Processing $snap_count snapshots..."
  log_file="$LOG_DIR/${case_name}.log"
  
  if $DRY_RUN; then
    echo "  DRY RUN: python3 $PP_SCRIPT --case-dir $case_dir --cpus $CPUS"
    continue
  fi
  
  if python3 "$PP_SCRIPT" --case-dir "$case_dir" --cpus "$CPUS" > "$log_file" 2>&1; then
    DONE=$((DONE + 1))
    echo "[$case_name] DONE ✓ (log: $log_file)"
  else
    FAILED=$((FAILED + 1))
    echo "[$case_name] FAILED ✗ (log: $log_file)"
    # Show last 5 lines of error
    tail -5 "$log_file" | sed "s/^/  /"
  fi
done

echo ""
echo "=================================================="
echo "Batch Post-Processing Complete"
echo "Total: $TOTAL | Done: $DONE | Failed: $FAILED | Skipped: $SKIPPED"
echo "Finished: $(date)"
echo "=================================================="
