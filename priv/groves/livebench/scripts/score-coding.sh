#!/usr/bin/env bash
# score-coding.sh — Execute a Python solution against JSON test cases in a
# bubblewrap sandbox. Returns JSON with score (0 or 1, pass@1).
#
# Usage:
#   ./score-coding.sh --solution FILE --test-cases-file FILE [OPTIONS]
#   ./score-coding.sh --solution FILE --test-cases JSON_STRING [OPTIONS]
#
# Required (one of):
#   --solution FILE          Path to file containing model's code response
#   --test-cases-file FILE   Path to file containing JSON test cases (PREFERRED)
#   --test-cases JSON        JSON string (use file instead to avoid quoting issues)
#
# Options:
#   --platform PLATFORM          "leetcode" or "atcoder" (default: leetcode)
#   --starter-code CODE          Starter code to prepend (prefer --starter-code-file)
#   --starter-code-file FILE     Path to file containing starter code (PREFERRED)
#   --timeout SECONDS            Per-test-case timeout (default: 10)
#
# Output (stdout): JSON object
#   {"score": 1, "passed": 4, "failed": 0, "total": 4, "errors": []}
#   {"score": 0, "passed": 2, "failed": 2, "total": 4, "errors": ["Case 3: ..."]}
#
# Exit codes:
#   0 = scoring completed (check JSON for results)
#   1 = missing arguments or prerequisites
#   2 = sandbox setup failed
#
# Reference: https://github.com/LiveBench/LiveBench (LCB_generation)

set -euo pipefail

SOLUTION=""
TEST_CASES=""
TEST_CASES_FILE=""
PLATFORM="leetcode"
STARTER_CODE=""
STARTER_CODE_FILE=""
TIMEOUT_PER_CASE="${SCORE_TIMEOUT:-10}"
MEMORY_LIMIT_KB="${SCORE_MEMORY_KB:-524288}"   # 512MB
FILE_LIMIT_KB="${SCORE_FILE_KB:-10240}"         # 10MB

# ── Parse arguments ─────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --solution)        SOLUTION="$2";        shift 2 ;;
        --test-cases-file) TEST_CASES_FILE="$2"; shift 2 ;;
        --test-cases)      TEST_CASES="$2";      shift 2 ;;
        --platform)        PLATFORM="$2";        shift 2 ;;
        --starter-code)      STARTER_CODE="$2";      shift 2 ;;
        --starter-code-file) STARTER_CODE_FILE="$2"; shift 2 ;;
        --timeout)         TIMEOUT_PER_CASE="$2"; shift 2 ;;
        *)
            echo '{"score": 0, "error": "Unknown argument: '"$1"'"}' >&2
            exit 1
            ;;
    esac
done

# ── Validate inputs ────────────────────────────────────────────────
if [[ -z "$SOLUTION" ]]; then
    echo '{"score": 0, "error": "Usage: score-coding.sh --solution FILE --test-cases-file FILE"}' >&2
    exit 1
fi

if [[ -z "$TEST_CASES_FILE" && -z "$TEST_CASES" ]]; then
    echo '{"score": 0, "error": "Must provide --test-cases-file or --test-cases"}' >&2
    exit 1
fi

if [[ ! -f "$SOLUTION" ]]; then
    echo "{\"score\": 0, \"error\": \"Solution file not found: $SOLUTION\"}" >&2
    exit 1
fi

if ! command -v bwrap &>/dev/null; then
    echo '{"score": 0, "error": "bubblewrap (bwrap) not installed"}' >&2
    exit 1
fi

if ! command -v python3 &>/dev/null; then
    echo '{"score": 0, "error": "python3 not found"}' >&2
    exit 1
fi

# ── Resolve starter code (prefer file, fall back to inline) ───────
if [[ -n "$STARTER_CODE_FILE" && -f "$STARTER_CODE_FILE" ]]; then
    STARTER_CODE=$(cat "$STARTER_CODE_FILE")
fi

# ── Prepare workspace ──────────────────────────────────────────────
WORKDIR=$(mktemp -d "/tmp/livebench-score-XXXXXX")
trap 'rm -rf "$WORKDIR"' EXIT

# Write starter code to workspace file (avoids shell quoting in Python -c)
echo "$STARTER_CODE" > "$WORKDIR/starter_code.txt"

# Read the solution and strip markdown fences
python3 -c "
import sys, re, os
with open(sys.argv[1]) as f:
    code = f.read()
# Strip <think> tags
code = re.sub(r'<think>.*?</think>', '', code, flags=re.DOTALL)
# Extract code from markdown fences
m = re.search(r'\`\`\`(?:python|py)?\s*\n(.*?)\`\`\`', code, re.DOTALL)
if m:
    code = m.group(1)
else:
    # Try generic fences
    m = re.search(r'\`\`\`\s*\n(.*?)\`\`\`', code, re.DOTALL)
    if m:
        code = m.group(1)
# Prepend starter code if provided (read from file to avoid shell quoting issues)
starter_path = os.path.join(sys.argv[2], 'starter_code.txt')
with open(starter_path) as sf:
    starter = sf.read()
if starter.strip():
    code = starter.strip() + '\n\n' + code
with open(os.path.join(sys.argv[2], 'solution.py'), 'w') as f:
    f.write(code)
" "$SOLUTION" "$WORKDIR"

# Write test cases to file (prefer --test-cases-file, fall back to --test-cases)
if [[ -n "$TEST_CASES_FILE" && -f "$TEST_CASES_FILE" ]]; then
    cp "$TEST_CASES_FILE" "$WORKDIR/test_cases.json"
else
    echo "$TEST_CASES" > "$WORKDIR/test_cases.json"
fi

# Generate the runner script
cat > "$WORKDIR/runner.py" << 'RUNNER_EOF'
import json
import sys
import signal
import subprocess
import io
import contextlib

def timeout_handler(signum, frame):
    raise TimeoutError("Execution timed out")

signal.signal(signal.SIGALRM, timeout_handler)

timeout_sec = int(sys.argv[1]) if len(sys.argv) > 1 else 10
platform = sys.argv[2] if len(sys.argv) > 2 else "leetcode"

# Load the solution code
try:
    with open("/work/solution.py") as f:
        solution_code = f.read()
except Exception as e:
    print(json.dumps({
        "score": 0, "passed": 0, "failed": 0, "total": 0,
        "errors": [f"Solution failed to load: {type(e).__name__}: {e}"]
    }))
    sys.exit(0)

# Load test cases
try:
    with open("/work/test_cases.json") as f:
        test_cases = json.loads(f.read())
except Exception as e:
    print(json.dumps({
        "score": 0, "passed": 0, "failed": 0, "total": 0,
        "errors": [f"Test cases failed to load: {type(e).__name__}: {e}"]
    }))
    sys.exit(0)

# Auto-decode double-encoded JSON strings (public_test_cases is stored as a
# JSON string in the dataset, so it may arrive double-encoded via shell quoting)
decode_attempts = 0
while isinstance(test_cases, str) and decode_attempts < 3:
    try:
        test_cases = json.loads(test_cases)
        decode_attempts += 1
    except (json.JSONDecodeError, TypeError):
        break

if not isinstance(test_cases, list):
    print(json.dumps({
        "score": 0, "passed": 0, "failed": 0, "total": 0,
        "errors": [f"test_cases is not a list (got {type(test_cases).__name__})"]
    }))
    sys.exit(0)

# Execute solution in isolated namespace
solution_ns = {}
try:
    exec(compile(solution_code, "solution.py", "exec"), solution_ns)
except Exception as e:
    print(json.dumps({
        "score": 0, "passed": 0, "failed": 0, "total": 0,
        "errors": [f"Solution failed to compile/exec: {type(e).__name__}: {e}"]
    }))
    sys.exit(0)

# Find the Solution class and its method (for functional tests)
solution_class = solution_ns.get("Solution")
solution_instance = None
method_name = None
if solution_class:
    solution_instance = solution_class()
    # Find the first non-dunder method
    for attr in dir(solution_instance):
        if not attr.startswith("_") and callable(getattr(solution_instance, attr)):
            method_name = attr
            break

passed = 0
failed = 0
errors = []

for i, tc in enumerate(test_cases, 1):
    signal.alarm(timeout_sec)
    try:
        testtype = tc.get("testtype", "functional")
        expected_output = tc.get("output", "")
        input_data = tc.get("input", "")

        if testtype == "stdin":
            # stdin/stdout test: run solution as subprocess to get hard SIGKILL timeout
            import subprocess
            proc_result = subprocess.run(
                ["python3", "/work/solution.py"],
                input=str(input_data),
                capture_output=True,
                text=True,
                timeout=timeout_sec
            )
            actual = proc_result.stdout.strip()
            expected = str(expected_output).strip()
            if actual == expected:
                passed += 1
            else:
                failed += 1
                err_detail = f"expected '{expected[:50]}', got '{actual[:50]}'"
                if proc_result.stderr.strip():
                    err_detail += f" (stderr: {proc_result.stderr.strip()[:100]})"
                errors.append(f"Case {i}: {err_detail}")

        else:
            # functional test: call Solution().method(input)
            if not solution_instance or not method_name:
                failed += 1
                errors.append(f"Case {i}: No Solution class or method found")
                continue

            method = getattr(solution_instance, method_name)

            # Parse input — it could be multiple args
            try:
                parsed_input = eval(input_data)
            except Exception:
                parsed_input = input_data

            # Call method with input
            if isinstance(parsed_input, tuple):
                actual = method(*parsed_input)
            elif isinstance(parsed_input, list):
                # Could be a single list arg or multiple args
                # Try as single arg first (most common for LeetCode)
                actual = method(parsed_input)
            else:
                actual = method(parsed_input)

            # Compare output
            try:
                expected = eval(str(expected_output))
            except Exception:
                expected = expected_output

            if str(actual).strip() == str(expected).strip():
                passed += 1
            elif actual == expected:
                passed += 1
            else:
                failed += 1
                errors.append(f"Case {i}: expected {expected!r}, got {actual!r}")

    except subprocess.TimeoutExpired:
        failed += 1
        errors.append(f"Case {i}: Timed out ({timeout_sec}s)")
    except TimeoutError:
        failed += 1
        errors.append(f"Case {i}: Timed out ({timeout_sec}s)")
    except Exception as e:
        failed += 1
        errors.append(f"Case {i}: {type(e).__name__}: {e}")
    finally:
        signal.alarm(0)

total = passed + failed
# pass@1: score is 1 only if ALL test cases pass
score = 1 if failed == 0 and total > 0 else 0

print(json.dumps({
    "score": score,
    "passed": passed,
    "failed": failed,
    "total": total,
    "errors": errors[:10]  # Limit error output
}))
RUNNER_EOF

# ── Run in bubblewrap sandbox ──────────────────────────────────────
BWRAP_ARGS=(
    --ro-bind /usr /usr
    --ro-bind /bin /bin
    --proc /proc
    --dev /dev
    --tmpfs /tmp
    --bind "$WORKDIR" /work
    --unshare-net
    --unshare-pid
    --die-with-parent
    --chdir /work
)

# Bind /lib and /lib64 only if they exist
[[ -d /lib ]] && BWRAP_ARGS+=(--ro-bind /lib /lib)
[[ -d /lib64 ]] && BWRAP_ARGS+=(--ro-bind /lib64 /lib64)
[[ -d /etc/alternatives ]] && BWRAP_ARGS+=(--ro-bind /etc/alternatives /etc/alternatives)

# Outer timeout: generous but finite — prevents runaway processes
TOTAL_TIMEOUT=$(( TIMEOUT_PER_CASE * 20 + 30 ))
CPU_LIMIT=$(( TIMEOUT_PER_CASE * 15 ))

RESULT=$(timeout --kill-after=10 "$TOTAL_TIMEOUT" \
    bwrap "${BWRAP_ARGS[@]}" \
    -- \
    /bin/bash -c "ulimit -v $MEMORY_LIMIT_KB -f $FILE_LIMIT_KB -t $CPU_LIMIT 2>/dev/null; python3 /work/runner.py $TIMEOUT_PER_CASE $PLATFORM" \
    2>/dev/null) || true

# If bwrap produced no output, report failure
if [[ -z "$RESULT" ]]; then
    echo '{"score": 0, "passed": 0, "failed": 0, "total": 0, "errors": ["Sandbox execution produced no output"]}'
    exit 2
fi

# Validate JSON and pass through
if echo "$RESULT" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
    echo "$RESULT"
else
    echo '{"score": 0, "passed": 0, "failed": 0, "total": 0, "errors": ["Sandbox produced invalid JSON"]}'
    exit 2
fi
