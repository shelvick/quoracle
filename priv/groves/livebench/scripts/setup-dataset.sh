#!/usr/bin/env bash
# setup-dataset.sh — Download LiveBench datasets from HuggingFace.
#
# Usage: ./setup-dataset.sh [release-date]
#   Default release: 2024-11-25
#
# Requires: uv (or python3 with 'datasets' already installed)
# Disk usage: ~5-10MB
#
# Output:
#   ~/.quoracle/benchmarks/livebench/data/{release}/math.jsonl
#   ~/.quoracle/benchmarks/livebench/data/{release}/reasoning.jsonl
#   ~/.quoracle/benchmarks/livebench/data/{release}/coding.jsonl
#   ~/.quoracle/benchmarks/livebench/data/{release}/language.jsonl
#   ~/.quoracle/benchmarks/livebench/data/{release}/data_analysis.jsonl
#   ~/.quoracle/benchmarks/livebench/data/{release}/instruction_following.jsonl

set -euo pipefail

RELEASE="${1:-2024-11-25}"
DATA_DIR="${HOME}/.quoracle/benchmarks/livebench/data/${RELEASE}"
VENV_DIR="${HOME}/.quoracle/benchmarks/.venv"
CATEGORIES=("math" "reasoning" "coding" "language" "data_analysis" "instruction_following")

mkdir -p "$DATA_DIR"

echo "=== LiveBench Dataset Setup ==="
echo "Release: $RELEASE"
echo "Target:  $DATA_DIR"
echo "Categories: ${CATEGORIES[*]}"
echo ""

# Check if already downloaded
existing=0
for cat in "${CATEGORIES[@]}"; do
    [[ -f "$DATA_DIR/$cat.jsonl" ]] && ((existing++)) || true
done

if [[ $existing -eq ${#CATEGORIES[@]} ]]; then
    echo "All category datasets already exist:"
    for cat in "${CATEGORIES[@]}"; do
        echo "  $cat.jsonl: $(wc -l < "$DATA_DIR/$cat.jsonl") questions"
    done
    echo ""
    echo "To re-download, delete the files first."
    exit 0
fi

# Set up Python environment with datasets library
PYTHON="python3"
if ! "$PYTHON" -c "import datasets" 2>/dev/null; then
    echo "Setting up Python environment with 'datasets' library..."
    if command -v uv &>/dev/null; then
        if [[ ! -d "$VENV_DIR" ]]; then
            uv venv "$VENV_DIR"
        fi
        source "$VENV_DIR/bin/activate"
        uv pip install datasets sympy pandas "antlr4-python3-runtime>=4.11,<4.12"
        PYTHON="$VENV_DIR/bin/python"
    elif command -v pip3 &>/dev/null; then
        pip3 install --user datasets
    else
        echo "ERROR: No package manager found. Install 'uv' or ensure 'datasets' is available."
        exit 1
    fi
    echo ""
fi

echo "Downloading LiveBench categories from HuggingFace..."
echo ""

"$PYTHON" - "$RELEASE" "$DATA_DIR" << 'PYEOF'
import json
import os
import sys
from datasets import load_dataset

release = sys.argv[1]
data_dir = sys.argv[2]
categories = ["math", "reasoning", "coding", "language", "data_analysis", "instruction_following"]

for category in categories:
    output_path = os.path.join(data_dir, f"{category}.jsonl")
    if os.path.exists(output_path):
        print(f"  {category}: already exists, skipping")
        continue

    print(f"  Downloading livebench/{category}...")
    try:
        ds = load_dataset(f"livebench/{category}", split="test")
    except Exception as e:
        print(f"  WARNING: Could not load livebench/{category}: {e}")
        print(f"  Skipping this category. You can retry later.")
        continue

    count = 0
    with open(output_path, "w") as f:
        for row in ds:
            # Include questions from this release or earlier
            row_release = str(row.get("livebench_release_date", ""))
            if row_release and row_release > release:
                continue

            record = {
                "question_id": row.get("question_id", ""),
                "category": category,
                "task": row.get("task", ""),
                "turns": row.get("turns", []),
                "ground_truth": row.get("ground_truth", ""),
                "livebench_release_date": row_release,
            }

            # Category-specific fields
            if category == "coding":
                original = row.get("original_json", {})
                if isinstance(original, str):
                    try:
                        original = json.loads(original)
                    except json.JSONDecodeError:
                        original = {}
                record["starter_code"] = original.get("starter_code", "")
                # public_test_cases is a top-level HF column, not inside original_json
                record["public_test_cases"] = row.get("public_test_cases", "")
                record["platform"] = original.get("platform", "")

            if category == "instruction_following":
                record["instruction_id_list"] = row.get("instruction_id_list", [])
                record["kwargs"] = row.get("kwargs", [])

            if category == "data_analysis":
                record["subtask"] = row.get("subtask", "")

            f.write(json.dumps(record) + "\n")
            count += 1

    print(f"  {category}: {count} questions -> {output_path}")

print("\nDone.")
PYEOF

echo ""
echo "=== Setup Complete ==="
for cat in "${CATEGORIES[@]}"; do
    if [[ -f "$DATA_DIR/$cat.jsonl" ]]; then
        echo "  $cat.jsonl: $(wc -l < "$DATA_DIR/$cat.jsonl") questions"
    else
        echo "  $cat.jsonl: NOT DOWNLOADED (may need retry)"
    fi
done
echo ""
echo "Next steps:"
echo "  1. Run: scripts/prepare-data.sh --release $RELEASE  (one-time data preparation)"
echo "  2. Create benchmark profiles in Quoracle (if not already done)"
echo "  3. Select the livebench grove in the Quoracle UI"
echo "  4. In Immediate Context, specify: release, solver_profile, categories (optional)"
echo "  5. Submit to start a run"
