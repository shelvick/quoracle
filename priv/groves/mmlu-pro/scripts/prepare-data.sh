#!/usr/bin/env bash
# prepare-data.sh — One-time preparation of MMLU-Pro dataset for benchmark runs.
#
# Converts raw JSONL into sequential question files with 5-shot CoT prompts,
# plus ground-truth.json and manifest.json. Run once per split (or per
# subject-filtered subset) after setup-dataset.sh downloads the raw data.
#
# Usage:
#   ./prepare-data.sh --split test
#   ./prepare-data.sh --split validation
#   ./prepare-data.sh --split test --subjects math,physics --output-name test-math
#
# Required:
#   --split NAME             "validation" (70 questions) or "test" (12,032)
#
# Options:
#   --subjects SUB[,SUB]     Comma-separated subject filter (default: all 14)
#   --output-name NAME       Output directory name under data/ (default: same as split)
#
# Prerequisites:
#   Dataset must already be downloaded via setup-dataset.sh.
#
# Output:
#   ~/.quoracle/benchmarks/mmlu-pro/data/{output-name}/
#     manifest.json      — Question count and category metadata
#     ground-truth.json  — Answer key keyed by question_id (for scoring)
#     questions/         — One JSON file per question (00000.json, 00001.json, ...)

set -euo pipefail

ALL_SUBJECTS="biology,business,chemistry,computer_science,economics,engineering,health,history,law,math,philosophy,physics,psychology,other"

# ── Parse arguments ──────────────────────────────────────────────────
SPLIT=""
SUBJECTS="$ALL_SUBJECTS"
OUTPUT_NAME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --split)       SPLIT="$2";       shift 2 ;;
        --subjects)    SUBJECTS="$2";    shift 2 ;;
        --output-name) OUTPUT_NAME="$2"; shift 2 ;;
        *)
            echo "ERROR: Unknown argument: $1" >&2
            echo "Usage: $0 --split validation|test [--subjects SUB,SUB] [--output-name NAME]" >&2
            exit 1
            ;;
    esac
done

if [[ -z "$SPLIT" ]]; then
    echo "ERROR: --split is required" >&2
    exit 1
fi

[[ -z "$OUTPUT_NAME" ]] && OUTPUT_NAME="$SPLIT"

# ── Validate dataset ────────────────────────────────────────────────
DATA_DIR="${HOME}/.quoracle/benchmarks/mmlu-pro/data"
DATASET_PATH="$DATA_DIR/${SPLIT}.jsonl"
VALIDATION_PATH="$DATA_DIR/validation.jsonl"
OUTPUT_DIR="$DATA_DIR/${OUTPUT_NAME}"

if [[ ! -f "$DATASET_PATH" ]]; then
    echo "ERROR: Dataset not found at $DATASET_PATH" >&2
    echo "Run setup-dataset.sh first." >&2
    exit 1
fi

if [[ ! -f "$VALIDATION_PATH" ]]; then
    echo "ERROR: Validation split not found at $VALIDATION_PATH" >&2
    echo "Run setup-dataset.sh first (needed for 5-shot CoT examples)." >&2
    exit 1
fi

# ── Clean and create output directory ────────────────────────────────
if [[ -d "$OUTPUT_DIR/questions" ]]; then
    echo "Removing existing prepared data..."
    rm -rf "$OUTPUT_DIR/questions"
fi
mkdir -p "$OUTPUT_DIR/questions"

echo "=== MMLU-Pro Data Preparation ==="
echo "Split:       $SPLIT"
echo "Subjects:    $SUBJECTS"
echo "Output:      $OUTPUT_DIR"
echo ""

# ── Build prepared data via Python ───────────────────────────────────
PYTHON="python3"
VENV_DIR="${HOME}/.quoracle/benchmarks/.venv"
if [[ -f "$VENV_DIR/bin/python" ]]; then
    PYTHON="$VENV_DIR/bin/python"
fi

"$PYTHON" - "$DATASET_PATH" "$OUTPUT_DIR" "$SUBJECTS" "$SPLIT" "$VALIDATION_PATH" << 'PYEOF'
import json
import os
import sys
import textwrap
from datetime import datetime, timezone

dataset_path = sys.argv[1]
output_dir = sys.argv[2]
subjects_str = sys.argv[3]
split = sys.argv[4]
validation_path = sys.argv[5]

subjects = set(s.strip() for s in subjects_str.split(","))
ALL_SUBJECTS = {"biology", "business", "chemistry", "computer_science", "economics",
                "engineering", "health", "history", "law", "math", "philosophy",
                "physics", "psychology", "other"}
filter_subjects = subjects != ALL_SUBJECTS

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

# ── Official MMLU-Pro prompt construction ────────────────────────────

def format_example(question, options, cot_content=""):
    if cot_content == "":
        cot_content = "Let's think step by step."
    if cot_content.startswith("A: "):
        cot_content = cot_content[3:]
    example = "Question: {}\nOptions: ".format(question)
    choice_map = "ABCDEFGHIJ"
    for i, opt in enumerate(options):
        example += "{}. {}\n".format(choice_map[i], opt)
    if cot_content == "":
        example += "Answer: "
    else:
        example += "Answer: " + cot_content + "\n\n"
    return example

def build_prompt(category, cot_examples, question, options):
    prompt = ("The following are multiple choice questions (with answers) about {}. "
              "Think step by step and then output the answer in the format of "
              "\"The answer is (X)\" at the end.\n\n").format(category)
    for ex in cot_examples:
        prompt += format_example(ex["question"], ex["options"], ex.get("cot_content", ""))
    prompt += format_example(question, options)
    return prompt

# ── Load validation split for 5-shot CoT examples ───────────────────
cot_examples_by_category = {}
with open(validation_path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        row = json.loads(line)
        cat = row.get("category", "other")
        cot_examples_by_category.setdefault(cat, []).append(row)

print("  Loaded 5-shot CoT examples for {} categories".format(len(cot_examples_by_category)))

# ── Load and filter questions ────────────────────────────────────────
all_rows = []
with open(dataset_path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        row = json.loads(line)
        category = row.get("category", "other")
        if filter_subjects and category not in subjects:
            continue
        all_rows.append(row)

# Sort by category for contiguous ranges in manifest
all_rows.sort(key=lambda r: r.get("category", "other"))

# ── Write sequential question files ─────────────────────────────────
ground_truth = {}
category_ranges = {}
current_category = None
category_start = 0
category_count = 0

for index, row in enumerate(all_rows):
    category = row.get("category", "other")
    qid = row["question_id"]

    # Track category ranges
    if category != current_category:
        if current_category is not None:
            category_ranges[current_category] = {"start": category_start, "count": category_count}
        current_category = category
        category_start = index
        category_count = 0

    # Ground truth (with file_index for scorer lookups)
    ground_truth[str(qid)] = {
        "answer": row["answer"],
        "answer_index": row.get("answer_index"),
        "category": category,
        "file_index": index,
    }

    # Build 5-shot CoT prompt
    cot_examples = cot_examples_by_category.get(category, [])
    prompt = build_prompt(category, cot_examples, row["question"], row["options"])

    # Question file (NO ground truth)
    question = {
        "question_id": qid,
        "category": category,
        "prompt": prompt,
    }
    question = split_long_strings(question)

    filepath = os.path.join(output_dir, "questions", "{:05d}.json".format(index))
    with open(filepath, "w") as qf:
        json.dump(question, qf, indent=2)

    category_count += 1

# Final category
if current_category is not None:
    category_ranges[current_category] = {"start": category_start, "count": category_count}

total = len(all_rows)
if total == 0:
    print("ERROR: No questions loaded. Check split and subjects.", file=sys.stderr)
    sys.exit(1)

# ── Write manifest.json ─────────────────────────────────────────────
manifest = {
    "benchmark": "mmlu-pro",
    "split": split,
    "total": total,
    "prompt_format": "5-shot-cot",
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
    cot_count = len(cot_examples_by_category.get(cat, []))
    print("    {}: {} questions (indices {}-{}, {} CoT examples)".format(
        cat, info["count"], info["start"], info["start"] + info["count"] - 1, cot_count))

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
