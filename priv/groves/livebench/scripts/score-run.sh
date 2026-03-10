#!/usr/bin/env bash
# score-run.sh — Score all LiveBench answers in a run directory.
#
# Iterates all answer files, calls the appropriate per-category scoring
# script, aggregates results, and writes report.json.
#
# Usage:
#   ./score-run.sh --run-dir PATH --data-dir PATH
#
# Required:
#   --run-dir PATH     Directory containing answers/ and config.json
#   --data-dir PATH    Directory containing ground-truth.json, manifest.json, and questions/
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

# Determine grove root (parent of scripts/)
GROVE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Determine Python to use
PYTHON="python3"
VENV_PYTHON="${HOME}/.quoracle/benchmarks/.venv/bin/python"
if [[ -f "$VENV_PYTHON" ]]; then
    PYTHON="$VENV_PYTHON"
fi

"$PYTHON" - "$RUN_DIR" "$DATA_DIR" "$GROVE_ROOT" "$PYTHON" << 'PYEOF'
import json
import os
import subprocess
import sys
from datetime import datetime, timezone

run_dir = sys.argv[1]
data_dir = sys.argv[2]
grove_root = sys.argv[3]
python_bin = sys.argv[4]

# ── Load ground truth and config ─────────────────────────────────────
with open(os.path.join(data_dir, "ground-truth.json")) as f:
    ground_truth = json.load(f)

with open(os.path.join(run_dir, "config.json")) as f:
    config = json.load(f)

scripts_dir = os.path.join(grove_root, "scripts")
total_expected = config.get("total_dispatched", 0)

# ── Build question lookup (file_index → path) ─────────────────────────
# Used by category-specific scorers that need question metadata
# (e.g., coding test_cases, math answer values).
question_by_qid = {}
for qid, gt in ground_truth.items():
    fi = gt.get("file_index")
    if fi is not None:
        question_by_qid[qid] = os.path.join(data_dir, "questions", "{:05d}.json".format(fi))

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
task_scores = {}      # category → task → [score, ...]
total_answered = 0
total_failed = 0

for fname in sorted(os.listdir(answers_dir)):
    if not fname.endswith(".txt"):
        continue

    answer_path = os.path.join(answers_dir, fname)
    try:
        file_index = int(fname.replace(".txt", ""))
    except ValueError:
        total_failed += 1
        continue

    qid = index_to_qid.get(file_index)
    if qid is None or qid not in ground_truth:
        total_failed += 1
        continue

    try:
        with open(answer_path) as f:
            response_text = f.read()
    except IOError:
        total_failed += 1
        continue

    gt = ground_truth[qid]
    cat = gt.get("category", "unknown")
    task = gt.get("task", "unknown")

    # Write response to temp file for scoring scripts
    resp_path = os.path.join(answers_dir, "resp-{}.txt".format(qid))
    with open(resp_path, "w") as f:
        f.write(response_text)

    # Write ground truth to file (avoids shell quoting issues)
    gt_value = gt.get("ground_truth", "")
    gt_path = os.path.join(answers_dir, "gt-{}.txt".format(qid))
    with open(gt_path, "w") as f:
        f.write(str(gt_value))

    score = 0.0
    try:
        if cat == "math":
            question_path = question_by_qid.get(qid, "")
            cmd = [python_bin, os.path.join(scripts_dir, "score-math.py"),
                   "--task", task,
                   "--response", resp_path,
                   "--ground-truth-file", gt_path]
            if question_path and os.path.exists(question_path):
                cmd.extend(["--question-text", question_path])
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)

        elif cat == "reasoning":
            cmd = [python_bin, os.path.join(scripts_dir, "score-reasoning.py"),
                   "--task", task,
                   "--response", resp_path,
                   "--ground-truth-file", gt_path]
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)

        elif cat == "language":
            cmd = [python_bin, os.path.join(scripts_dir, "score-language.py"),
                   "--task", task,
                   "--response", resp_path,
                   "--ground-truth-file", gt_path]
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)

        elif cat == "coding":
            question_path = question_by_qid.get(qid, "")
            test_cases = ""
            platform = "leetcode"
            starter_code = ""
            if question_path and os.path.exists(question_path):
                with open(question_path) as qf:
                    q_data = json.load(qf)
                test_cases = q_data.get("public_test_cases", "")
                platform = q_data.get("platform", "leetcode")
                starter_code = q_data.get("starter_code", "")

            tc_path = os.path.join(answers_dir, "tc-{}.json".format(qid))
            with open(tc_path, "w") as f:
                f.write(str(test_cases))

            cmd = [os.path.join(scripts_dir, "score-coding.sh"),
                   "--solution", resp_path,
                   "--test-cases-file", tc_path,
                   "--platform", platform]

            if starter_code:
                sc_path = os.path.join(answers_dir, "sc-{}.py".format(qid))
                with open(sc_path, "w") as f:
                    f.write(starter_code)
                cmd.extend(["--starter-code-file", sc_path])

            result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)

        elif cat == "data_analysis":
            subtask = gt.get("task", task)
            cmd = [python_bin, os.path.join(scripts_dir, "score-tables.py"),
                   "--task", subtask,
                   "--response-file", resp_path,
                   "--ground-truth-file", gt_path]
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)

        elif cat == "instruction_following":
            constraints = {
                "instruction_id_list": gt.get("instruction_id_list", []),
                "kwargs": gt.get("kwargs", [])
            }
            constraints_path = os.path.join(answers_dir, "constraints-{}.json".format(qid))
            with open(constraints_path, "w") as f:
                json.dump(constraints, f)

            cmd = [python_bin, os.path.join(scripts_dir, "score-instructions.py"),
                   "--response-file", resp_path,
                   "--constraints-file", constraints_path]
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)

        else:
            print("  WARNING: Unknown category '{}' for question {}, scoring as 0.0".format(cat, qid))
            result = None

        if result is not None and result.returncode == 0:
            try:
                parsed = json.loads(result.stdout.strip())
                score = float(parsed.get("score", 0.0))
            except (json.JSONDecodeError, ValueError):
                score = 0.0
        elif result is not None:
            print("  WARNING: Scoring failed for {} ({}/{}): {}".format(
                qid, cat, task, result.stderr[:200]))

    except subprocess.TimeoutExpired:
        print("  WARNING: Scoring timed out for {} ({}/{})".format(qid, cat, task))
    except Exception as e:
        print("  WARNING: Scoring error for {} ({}/{}): {}".format(qid, cat, task, e))

    task_scores.setdefault(cat, {}).setdefault(task, []).append(score)
    total_answered += 1

# ── Cleanup temp scoring files ──────────────────────────────────────────
for f in os.listdir(answers_dir):
    if (f.startswith("resp-") or f.startswith("gt-") or f.startswith("tc-") or
            f.startswith("sc-") or f.startswith("constraints-")):
        try:
            os.remove(os.path.join(answers_dir, f))
        except OSError:
            pass

# ── Compute aggregates ────────────────────────────────────────────────
# Official LiveBench: macro-average of per-task accuracies within each
# category, then macro-average of category scores for Global Average.

category_results = {}
for cat, tasks in sorted(task_scores.items()):
    per_task = {}
    for task, scores in sorted(tasks.items()):
        per_task[task] = sum(scores) / len(scores) if scores else 0.0

    cat_accuracy = sum(per_task.values()) / len(per_task) if per_task else 0.0

    category_results[cat] = {
        "total": sum(len(s) for s in tasks.values()),
        "accuracy": cat_accuracy,
        "per_task": per_task,
        "failed": 0,
    }

# Global average = macro-average of category scores
global_accuracy = (sum(cr["accuracy"] for cr in category_results.values()) /
                   len(category_results)) if category_results else 0.0

# ── Write report.json ─────────────────────────────────────────────────
report = {
    "run_id": config.get("run_id", ""),
    "benchmark": "livebench",
    "profile": config.get("solver_profile", ""),
    "started_at": config.get("started_at", ""),
    "completed_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "aggregate": {
        "total": total_answered,
        "accuracy": global_accuracy,
        "failed": total_expected - total_answered if total_expected > 0 else 0,
    },
    "categories": category_results,
}

with open(os.path.join(run_dir, "report.json"), "w") as f:
    json.dump(report, f, indent=2)

# ── Print summary ─────────────────────────────────────────────────────
print("\n=== LiveBench Scoring Complete ===\n")
for cat, cr in sorted(category_results.items()):
    print("  {}: {:.1f}%".format(cat, cr["accuracy"] * 100))
    for task, score in sorted(cr["per_task"].items()):
        task_count = len(task_scores[cat][task])
        print("    {}: {:.1f}% ({} questions)".format(task, score * 100, task_count))

print("\n  Global Average: {:.1f}%".format(global_accuracy * 100))
print("  Total answered: {}".format(total_answered))
if total_expected - total_answered > 0:
    print("  Failed/missing: {}".format(total_expected - total_answered))
print("\n  Report: {}".format(os.path.join(run_dir, "report.json")))

PYEOF
