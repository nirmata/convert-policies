#!/bin/bash
# Run the benchmark N times and merge results into benchmark_latest.json.
#
# Usage:
#   ./scripts/run_n_times.sh 3 --persistent --tool claude cursor
#   ./scripts/run_n_times.sh 3 --containerized --tool nctl
#
# First argument is the number of runs. Remaining arguments are passed
# to benchmark.py as-is.
set -e

N="${1:?Usage: run_n_times.sh <N> [benchmark.py args...]}"
shift

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Stage run files in /tmp so the merge glob doesn't pick up unrelated results/
RUN_DIR="/tmp/policy-bench/multi-run-$$"
RUN_FILES=()

mkdir -p "$RUN_DIR"

for i in $(seq 1 "$N"); do
    echo ""
    echo "================================================================"
    echo "  RUN $i / $N"
    echo "================================================================"
    echo ""

    python3 "$REPO_ROOT/benchmark.py" "$@"

    # Find the benchmark_*.json just produced (newest file in results/)
    LATEST=$(ls -t "$REPO_ROOT/results/benchmark_"*.json 2>/dev/null | head -1)
    if [ -z "$LATEST" ]; then
        echo "Error: no benchmark_*.json found after run $i" >&2
        exit 1
    fi

    # Move it to the runs/ dir with a run number
    DEST="$RUN_DIR/run_${i}_$(basename "$LATEST")"
    cp "$LATEST" "$DEST"
    RUN_FILES+=("$DEST")
    echo "  Run $i saved to: $DEST"
done

echo ""
echo "================================================================"
echo "  MERGING $N RUNS"
echo "================================================================"
echo ""

python3 "$REPO_ROOT/scripts/merge_runs.py" "${RUN_FILES[@]}"

echo ""
echo "Done. Results in results/benchmark_latest.json"
