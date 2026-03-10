#!/usr/bin/env bash
# prepare-data.sh — One-time preparation of LiveBench dataset for benchmark runs.
#
# Converts category JSONL files into sequential question files, plus
# ground-truth.json and manifest.json. Run once per release (or per
# category-filtered subset) after setup-dataset.sh downloads the raw data.
#
# Usage:
#   ./prepare-data.sh --release 2024-11-25
#   ./prepare-data.sh --release 2024-11-25 --categories math,reasoning --output-name 2024-11-25-math
#
# Required:
#   --release DATE           Dataset release date (e.g., 2024-11-25)
#
# Options:
#   --categories CAT[,CAT]   Comma-separated category filter (default: all six)
#   --output-name NAME       Output directory name under data/ (default: same as release)
#
# Prerequisites:
#   Dataset must already be downloaded via setup-dataset.sh.
#
# Output:
#   ~/.quoracle/benchmarks/livebench/data/{output-name}/
#     manifest.json      — Question count and category metadata
#     ground-truth.json  — Answer key keyed by question_id (for scoring)
#     questions/         — One JSON file per question (00000.json, 00001.json, ...)
#
# Note: The raw JSONL files in data/{release}/ are NOT modified. Prepared
#       data is written alongside them (or to a separate output-name directory).

set -euo pipefail

ALL_CATEGORIES="math,reasoning,coding,language,data_analysis,instruction_following"

# ── Parse arguments ──────────────────────────────────────────────────
RELEASE=""
CATEGORIES="$ALL_CATEGORIES"
OUTPUT_NAME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release)     RELEASE="$2";     shift 2 ;;
        --categories)  CATEGORIES="$2";  shift 2 ;;
        --output-name) OUTPUT_NAME="$2"; shift 2 ;;
        *)
            echo "ERROR: Unknown argument: $1" >&2
            echo "Usage: $0 --release DATE [--categories CAT,CAT] [--output-name NAME]" >&2
            exit 1
            ;;
    esac
done

if [[ -z "$RELEASE" ]]; then
    echo "ERROR: --release is required" >&2
    exit 1
fi

[[ -z "$OUTPUT_NAME" ]] && OUTPUT_NAME="$RELEASE"

# ── Validate dataset ────────────────────────────────────────────────
DATA_DIR="${HOME}/.quoracle/benchmarks/livebench/data"
RAW_DIR="$DATA_DIR/${RELEASE}"
OUTPUT_DIR="$DATA_DIR/${OUTPUT_NAME}"

if [[ ! -d "$RAW_DIR" ]]; then
    echo "ERROR: Dataset not found at $RAW_DIR" >&2
    echo "Run setup-dataset.sh $RELEASE first." >&2
    exit 1
fi

# ── Clean and create output directory ────────────────────────────────
if [[ -d "$OUTPUT_DIR/questions" ]]; then
    echo "Removing existing prepared data..."
    rm -rf "$OUTPUT_DIR/questions"
fi
mkdir -p "$OUTPUT_DIR/questions"

echo "=== LiveBench Data Preparation ==="
echo "Release:     $RELEASE"
echo "Categories:  $CATEGORIES"
echo "Output:      $OUTPUT_DIR"
echo ""

# ── Build prepared data via Python ───────────────────────────────────
PYTHON="python3"
VENV_DIR="${HOME}/.quoracle/benchmarks/.venv"
if [[ -f "$VENV_DIR/bin/python" ]]; then
    PYTHON="$VENV_DIR/bin/python"
fi

"$PYTHON" - "$RAW_DIR" "$OUTPUT_DIR" "$CATEGORIES" "$RELEASE" << 'PYEOF'
import json
import os
import sys
import textwrap
from datetime import datetime, timezone

raw_dir = sys.argv[1]
output_dir = sys.argv[2]
categories = [c.strip() for c in sys.argv[3].split(",")]
release = sys.argv[4]

# ── Line-length safety ───────────────────────────────────────────────
MAX_LINE = 1400

def split_long_strings(obj):
    """Recursively split long strings into lists of chunks for file_read safety."""
    if isinstance(obj, str):
        if len(obj) <= MAX_LINE:
            return obj
        return textwrap.wrap(obj, width=MAX_LINE, break_long_words=False, break_on_hyphens=False)
    elif isinstance(obj, list):
        result = []
        for item in obj:
            processed = split_long_strings(item)
            if isinstance(processed, list) and isinstance(item, str):
                result.extend(processed)
            else:
                result.append(processed)
        return result
    elif isinstance(obj, dict):
        return {k: split_long_strings(v) for k, v in obj.items()}
    return obj

# Extra fields to carry into question files (category-specific)
EXTRA_FIELDS = {
    "coding": ["starter_code", "public_test_cases", "platform"],
    "instruction_following": ["instruction_id_list", "kwargs"],
    "data_analysis": ["subtask"],
}

# ── Load questions by category, sorted for contiguous ranges ─────────
all_rows = []
for category in categories:
    path = os.path.join(raw_dir, "{}.jsonl".format(category))
    if not os.path.exists(path):
        print("  WARNING: {}.jsonl not found, skipping".format(category))
        continue

    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            row["_category"] = category
            all_rows.append(row)

# Sort by category for contiguous ranges (preserves order within category)
all_rows.sort(key=lambda r: r["_category"])

# ── Write sequential question files ─────────────────────────────────
ground_truth = {}
category_ranges = {}
current_category = None
category_start = 0
category_count = 0
category_tasks = {}  # category → set of task names

for index, row in enumerate(all_rows):
    category = row["_category"]
    qid = row["question_id"]

    # Track category ranges
    if category != current_category:
        if current_category is not None:
            category_ranges[current_category] = {
                "start": category_start,
                "count": category_count,
                "tasks": sorted(category_tasks.get(current_category, set())),
            }
        current_category = category
        category_start = index
        category_count = 0

    task = row.get("task", "")
    category_tasks.setdefault(category, set()).add(task)

    # Ground truth (for scoring, NEVER sent to solvers)
    gt_entry = {
        "ground_truth": row.get("ground_truth", ""),
        "category": category,
        "task": task,
        "file_index": index,
    }
    if category == "instruction_following":
        gt_entry["instruction_id_list"] = row.get("instruction_id_list", [])
        gt_entry["kwargs"] = row.get("kwargs", [])
    ground_truth[qid] = gt_entry

    # Solver-facing question (NO ground truth)
    question = {
        "question_id": qid,
        "category": category,
        "task": task,
        "turns": row.get("turns", []),
    }
    for field in EXTRA_FIELDS.get(category, []):
        if field in row:
            question[field] = row[field]

    question = split_long_strings(question)

    filepath = os.path.join(output_dir, "questions", "{:05d}.json".format(index))
    with open(filepath, "w") as qf:
        json.dump(question, qf, indent=2)

    category_count += 1

# Final category
if current_category is not None:
    category_ranges[current_category] = {
        "start": category_start,
        "count": category_count,
        "tasks": sorted(category_tasks.get(current_category, set())),
    }

total = len(all_rows)
if total == 0:
    print("ERROR: No questions loaded. Check dataset and categories.", file=sys.stderr)
    sys.exit(1)

# ── Write manifest.json ─────────────────────────────────────────────
manifest = {
    "benchmark": "livebench",
    "release": release,
    "total": total,
    "prepared_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "categories": category_ranges,
}
with open(os.path.join(output_dir, "manifest.json"), "w") as f:
    json.dump(manifest, f, indent=2)

# ── Write ground-truth.json ─────────────────────────────────────────
with open(os.path.join(output_dir, "ground-truth.json"), "w") as f:
    json.dump(ground_truth, f, indent=2)

# ── Summary ──────────────────────────────────────────────────────────
print("\n  Total: {} questions across {} categories".format(total, len(category_ranges)))
for cat, info in sorted(category_ranges.items()):
    print("    {}: {} questions (indices {}-{}, tasks: {})".format(
        cat, info["count"], info["start"], info["start"] + info["count"] - 1,
        ", ".join(info["tasks"])))

PYEOF

echo ""
echo "=== Data Prepared ==="
echo ""
echo "Files created:"
echo "  $OUTPUT_DIR/manifest.json"
echo "  $OUTPUT_DIR/ground-truth.json"
echo "  $OUTPUT_DIR/questions/  (sequential numbering, 5-digit)"
echo ""
echo "Run benchmarks via the Quoracle UI — no per-run preparation needed."
