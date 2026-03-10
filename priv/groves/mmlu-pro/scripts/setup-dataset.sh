#!/usr/bin/env bash
# setup-dataset.sh — Download and convert MMLU-Pro from HuggingFace to JSONL.
#
# Run this once before your first benchmark run.
# Requires: uv (or python3 with 'datasets' already installed)
# Disk usage: ~15-20MB
#
# Output:
#   ~/.quoracle/benchmarks/mmlu-pro/data/test.jsonl        (12,032 questions)
#   ~/.quoracle/benchmarks/mmlu-pro/data/validation.jsonl   (70 questions)

set -euo pipefail

DATA_DIR="${HOME}/.quoracle/benchmarks/mmlu-pro/data"
VENV_DIR="${HOME}/.quoracle/benchmarks/.venv"
mkdir -p "$DATA_DIR"

# Check if already downloaded
if [[ -f "$DATA_DIR/test.jsonl" && -f "$DATA_DIR/validation.jsonl" ]]; then
    echo "Dataset already exists at $DATA_DIR"
    echo "  test.jsonl:       $(wc -l < "$DATA_DIR/test.jsonl") questions"
    echo "  validation.jsonl: $(wc -l < "$DATA_DIR/validation.jsonl") questions"
    echo ""
    echo "To re-download, delete these files first."
    exit 0
fi

echo "=== MMLU-Pro Dataset Setup ==="
echo "Target: $DATA_DIR"
echo ""

# Set up Python environment with datasets library
PYTHON="python3"
if ! "$PYTHON" -c "import datasets" 2>/dev/null; then
    echo "Setting up Python environment with 'datasets' library..."
    if command -v uv &>/dev/null; then
        if [[ ! -d "$VENV_DIR" ]]; then
            uv venv "$VENV_DIR"
        fi
        source "$VENV_DIR/bin/activate"
        uv pip install datasets
        PYTHON="$VENV_DIR/bin/python"
    elif command -v pip3 &>/dev/null; then
        pip3 install --user datasets
    else
        echo "ERROR: No package manager found. Install 'uv' or ensure 'datasets' is available."
        exit 1
    fi
    echo ""
fi

echo "Downloading MMLU-Pro from HuggingFace (TIGER-Lab/MMLU-Pro)..."
echo ""

"$PYTHON" << 'PYEOF'
import json
import os
from datasets import load_dataset

data_dir = os.path.expanduser("~/.quoracle/benchmarks/mmlu-pro/data")

print("Loading dataset...")
dataset = load_dataset("TIGER-Lab/MMLU-Pro")

for split_name in ["test", "validation"]:
    split = dataset[split_name]
    output_path = os.path.join(data_dir, f"{split_name}.jsonl")

    with open(output_path, "w") as f:
        for row in split:
            # Filter out N/A placeholder options
            options_raw = row.get("options", [])
            options = [opt for opt in options_raw if opt and opt.strip() != "N/A"]

            # Map to letter labels (A, B, C, ...)
            option_labels = [chr(65 + i) for i in range(len(options))]

            record = {
                "question_id": row["question_id"],
                "question": row["question"],
                "options": options,                  # List of strings (matching official format)
                "answer": row["answer"],             # Ground truth letter
                "answer_index": row["answer_index"], # Ground truth index
                "category": row["category"],
                "src": row.get("src", ""),
                "cot_content": row.get("cot_content", ""),  # CoT for few-shot (validation split)
            }
            f.write(json.dumps(record) + "\n")

    count = len(split)
    print(f"  {split_name}: {count} questions -> {output_path}")

print("\nDone.")
PYEOF

echo ""
echo "=== Setup Complete ==="
echo "  test.jsonl:       $(wc -l < "$DATA_DIR/test.jsonl") questions"
echo "  validation.jsonl: $(wc -l < "$DATA_DIR/validation.jsonl") questions"
echo ""
echo "Next steps:"
echo "  1. Run: scripts/prepare-data.sh --split test  (one-time data preparation)"
echo "  2. Create benchmark profiles in Quoracle (if not already done)"
echo "  3. Select the mmlu-pro grove in the Quoracle UI"
echo "  4. In Immediate Context, specify: split, answerer_profile, subjects (optional)"
echo "  5. Submit to start a run"
