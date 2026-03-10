#!/usr/bin/env bash
# score-run.sh — Score all MMLU-Pro answers in a run directory.
#
# Iterates all answer files, applies 3-tier regex letter extraction
# (matching official MMLU-Pro evaluation), aggregates results, and
# writes report.json.
#
# Usage:
#   ./score-run.sh --run-dir PATH --data-dir PATH
#
# Required:
#   --run-dir PATH     Directory containing answers/ and config.json
#   --data-dir PATH    Directory containing ground-truth.json and manifest.json
#
# Output:
#   {run-dir}/report.json — Full benchmark report
#   Prints summary to stdout

set -euo pipefail

RUN_DIR=""
DATA_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --run-dir)  RUN_DIR="$2";  shift 2 ;;
        --data-dir) DATA_DIR="$2"; shift 2 ;;
        *)
            echo "ERROR: Unknown argument: $1" >&2
            echo "Usage: $0 --run-dir PATH --data-dir PATH" >&2
            exit 1
            ;;
    esac
done

if [[ -z "$RUN_DIR" ]]; then
    echo "ERROR: --run-dir is required" >&2
    exit 1
fi
if [[ -z "$DATA_DIR" ]]; then
    echo "ERROR: --data-dir is required" >&2
    exit 1
fi

if [[ ! -d "$RUN_DIR" ]]; then
    echo "ERROR: Run directory not found: $RUN_DIR" >&2
    exit 1
fi

PYTHON="python3"
VENV_PYTHON="${HOME}/.quoracle/benchmarks/.venv/bin/python"
if [[ -f "$VENV_PYTHON" ]]; then
    PYTHON="$VENV_PYTHON"
fi

"$PYTHON" - "$RUN_DIR" "$DATA_DIR" << 'PYEOF'
import json
import os
import re
import sys
from datetime import datetime, timezone

run_dir = sys.argv[1]
data_dir = sys.argv[2]

# ── Load ground truth and config ─────────────────────────────────────
with open(os.path.join(data_dir, "ground-truth.json")) as f:
    ground_truth = json.load(f)

with open(os.path.join(run_dir, "config.json")) as f:
    config = json.load(f)

total_expected = config.get("total_dispatched", 0)

# ── 3-tier regex letter extraction ────────────────────────────────────
# Matches official MMLU-Pro evaluation:
# https://github.com/TIGER-AI-Lab/MMLU-Pro

def extract_letter(response_text):
    """Extract answer letter A-J from response using 3-tier cascade."""
    response_text = response_text.replace("**", "")

    # Tier 1: "answer is (X)" or "answer is X"
    m = re.search(r'answer is \(?([A-J])\)?', response_text)
    if m:
        return m.group(1)

    # Tier 2: "Answer: X" (LAST occurrence via greedy .*)
    m = re.search(r'.*[aA]nswer:\s*([A-J])', response_text, re.DOTALL)
    if m:
        return m.group(1)

    # Tier 3: Last standalone letter A-J
    matches = re.findall(r'\b([A-J])\b', response_text)
    if matches:
        return matches[-1]

    return None

# ── Build file_index → question_id lookup ──────────────────────────────
# Answer files are named by file_index (e.g., 00042.txt), not question_id.
# ground-truth.json maps question_id → {file_index, answer, category, ...}.
index_to_qid = {}
for qid, gt in ground_truth.items():
    fi = gt.get("file_index")
    if fi is not None:
        index_to_qid[int(fi)] = qid

# ── Iterate all answer files (flat directory) ──────────────────────────
answers_dir = os.path.join(run_dir, "answers")
subject_results = {}
total_correct = 0
total_answered = 0
total_unanswered = 0

for fname in sorted(os.listdir(answers_dir)):
    if not fname.endswith(".txt"):
        continue

    answer_path = os.path.join(answers_dir, fname)
    try:
        file_index = int(fname.replace(".txt", ""))
    except ValueError:
        continue

    qid = index_to_qid.get(file_index)
    if qid is None or qid not in ground_truth:
        continue

    try:
        with open(answer_path) as f:
            response_text = f.read()
    except IOError:
        continue

    gt = ground_truth[qid]
    gt_letter = gt.get("answer", "")
    subject = gt.get("category", "unknown")

    extracted = extract_letter(response_text)

    subj = subject_results.setdefault(subject, {"correct": 0, "total": 0, "unanswered": 0})
    subj["total"] += 1
    total_answered += 1

    if extracted is None:
        subj["unanswered"] += 1
        total_unanswered += 1
    elif extracted == gt_letter:
        subj["correct"] += 1
        total_correct += 1

# ── Compute aggregate ────────────────────────────────────────────────
overall_accuracy = total_correct / total_answered if total_answered > 0 else 0.0
total_failed = total_expected - total_answered if total_expected > 0 else 0

# ── Build per-subject report ─────────────────────────────────────────
categories_report = {}
for subject, sr in sorted(subject_results.items()):
    categories_report[subject] = {
        "total": sr["total"],
        "correct": sr["correct"],
        "accuracy": sr["correct"] / sr["total"] if sr["total"] > 0 else 0.0,
    }

# ── Write report.json ─────────────────────────────────────────────────
report = {
    "run_id": config.get("run_id", ""),
    "benchmark": "mmlu-pro",
    "profile": config.get("answerer_profile", ""),
    "started_at": config.get("started_at", ""),
    "completed_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "aggregate": {
        "total": total_answered,
        "correct": total_correct,
        "accuracy": overall_accuracy,
        "unanswered": total_unanswered,
        "failed": total_failed,
    },
    "categories": categories_report,
}

with open(os.path.join(run_dir, "report.json"), "w") as f:
    json.dump(report, f, indent=2)

# ── Print summary ─────────────────────────────────────────────────────
print("\n=== MMLU-Pro Scoring Complete ===\n")
for subject, sr in sorted(subject_results.items()):
    acc = sr["correct"] / sr["total"] if sr["total"] > 0 else 0.0
    print("  {}: {:.1f}% ({}/{})".format(subject, acc * 100, sr["correct"], sr["total"]))
    if sr["unanswered"] > 0:
        print("    (unanswered: {})".format(sr["unanswered"]))

print("\n  Overall: {:.1f}% ({}/{})".format(overall_accuracy * 100, total_correct, total_answered))
if total_unanswered > 0:
    print("  Unanswered (extraction failures): {}".format(total_unanswered))
if total_failed > 0:
    print("  Failed/missing: {}".format(total_failed))
print("\n  Report: {}".format(os.path.join(run_dir, "report.json")))

PYEOF
