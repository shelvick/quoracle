#!/usr/bin/env python3
"""Score math answers for LiveBench.

Implements task-specific scoring matching the official LiveBench evaluation:
  - olympiad:   Comma-separated integer list, Levenshtein edit distance (partial credit)
  - AMPS_Hard:  LaTeX extraction + SymPy symbolic equivalence (string fallback)
  - math_comp:  AMC letter extraction (repeated/boxed/value match) or AIME numeric match

Usage:
    score-math.py --task TASK --response FILE --ground-truth GT [--question-text FILE]

Returns JSON to stdout: {"score": 0.0-1.0}
Exit code 0 = scoring completed, 1 = error.

Reference: https://github.com/LiveBench/LiveBench/tree/main/livebench/process_results/math
"""
import argparse
import json
import re
import sys

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

def strip_think_tags(text):
    """Remove <think>...</think> blocks (model reasoning traces)."""
    return re.sub(r"<think>.*?</think>", "", text, flags=re.DOTALL)


def extract_boxed(text):
    """Extract content from the LAST \\boxed{...} in text, handling nested braces."""
    # Find all \boxed{ positions
    pattern = r"\\boxed\s*\{"
    matches = list(re.finditer(pattern, text))
    if not matches:
        return None
    # Take the last one
    start = matches[-1].end()
    depth = 1
    i = start
    while i < len(text) and depth > 0:
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
        i += 1
    if depth == 0:
        content = text[start:i - 1].strip()
        # Strip \text{} and \textbf{} wrappers
        content = re.sub(r"\\text\{([^}]*)\}", r"\1", content)
        content = re.sub(r"\\textbf\{([^}]*)\}", r"\1", content)
        content = content.strip().strip("\\").strip()
        return content
    return None


def extract_solution_tags(text):
    """Extract content from <solution>...</solution> tags (last match)."""
    matches = re.findall(r"<solution>(.*?)</solution>", text, re.DOTALL | re.IGNORECASE)
    if matches:
        return matches[-1].strip()
    # Try malformed: </solution>...<solution> (reversed tags)
    matches = re.findall(r"</solution>(.*?)<solution>", text, re.DOTALL | re.IGNORECASE)
    if matches:
        return matches[-1].strip()
    return None


def parse_comma_integers(text):
    """Parse comma-separated integers from text. Returns list of ints or None."""
    if not text:
        return None
    # Remove whitespace, strip surrounding non-digit chars
    cleaned = text.strip()
    # Extract all integers separated by commas
    parts = re.split(r"\s*,\s*", cleaned)
    result = []
    for p in parts:
        p = p.strip()
        if p.lstrip("-").isdigit():
            result.append(int(p))
        else:
            # Try extracting just the number
            m = re.search(r"-?\d+", p)
            if m:
                result.append(int(m.group()))
    return result if result else None


# ---------------------------------------------------------------------------
# Levenshtein edit distance (for olympiad scoring)
# ---------------------------------------------------------------------------

def levenshtein_distance(s1, s2):
    """Compute Levenshtein edit distance between two sequences."""
    n, m = len(s1), len(s2)
    if n == 0:
        return m
    if m == 0:
        return n
    dp = list(range(m + 1))
    for i in range(1, n + 1):
        prev = dp[0]
        dp[0] = i
        for j in range(1, m + 1):
            temp = dp[j]
            if s1[i - 1] == s2[j - 1]:
                dp[j] = prev
            else:
                dp[j] = 1 + min(prev, dp[j], dp[j - 1])
            prev = temp
    return dp[m]


# ---------------------------------------------------------------------------
# Olympiad scoring (proof rearrangement)
# ---------------------------------------------------------------------------

def score_olympiad(response, ground_truth):
    """Score olympiad (IMO/USAMO) proof rearrangement.

    Ground truth: comma-separated integers (e.g., "1,6,7,2,3,4,5").
    Scoring: Levenshtein edit distance with partial credit.
    """
    gt_ints = parse_comma_integers(ground_truth)
    if not gt_ints:
        return 0.0

    # Extraction cascade: (1) last "answer:" → integers, (2) \boxed{}, (3) last line
    extracted = None

    # 1. Last "answer:" occurrence
    answer_matches = list(re.finditer(r"answer\s*:", response, re.IGNORECASE))
    if answer_matches:
        after = response[answer_matches[-1].end():]
        extracted = parse_comma_integers(after.split("\n")[0])

    # 2. \boxed{} content
    if not extracted:
        boxed = extract_boxed(response)
        if boxed:
            extracted = parse_comma_integers(boxed)

    # 3. Last line
    if not extracted:
        lines = [l.strip() for l in response.strip().split("\n") if l.strip()]
        if lines:
            extracted = parse_comma_integers(lines[-1])

    # 4. Fallback: find last comma-separated integer sequence in response
    if not extracted:
        # Find all sequences of comma-separated numbers
        seqs = re.findall(r"\d+(?:\s*,\s*\d+)+", response)
        if seqs:
            extracted = parse_comma_integers(seqs[-1])

    if not extracted:
        return 0.0

    # Levenshtein edit distance scoring
    dist = levenshtein_distance(extracted, gt_ints)
    max_len = max(len(extracted), len(gt_ints))
    if max_len == 0:
        return 1.0
    return round(1.0 - (dist / max_len), 4)


# ---------------------------------------------------------------------------
# AMPS_Hard scoring (LaTeX symbolic equivalence)
# ---------------------------------------------------------------------------

def normalize_latex_answer(text):
    """Normalize a LaTeX answer string (Minerva method)."""
    if not text:
        return ""
    s = text.strip()
    # Remove integration constants
    s = re.sub(r"\+\s*[Cc]\b", "", s)
    # Convert frac variants
    s = s.replace("\\dfrac", "\\frac").replace("\\tfrac", "\\frac")
    # Convert \fbox to \boxed
    s = s.replace("\\fbox", "\\boxed")
    # Remove spacing commands
    for cmd in ["\\left", "\\right", "\\bigl", "\\bigr", "\\Bigl", "\\Bigr",
                "\\,", "\\;", "\\!", "\\quad", "\\qquad"]:
        s = s.replace(cmd, "")
    # Remove newlines
    s = s.replace("\n", " ")
    # \cdot → *
    s = s.replace("\\cdot", "*")
    return s.strip()


def normalize_final_answer(text):
    """Minerva-style final answer normalization (from Lewkowycz et al. 2022)."""
    if not text:
        return ""
    s = text.strip()
    # Split on = and take last part
    if "=" in s:
        s = s.split("=")[-1].strip()
    # Strip $ delimiters
    s = s.strip("$").strip()
    # Strip \text{} and \textbf{}
    s = re.sub(r"\\text\{([^}]*)\}", r"\1", s)
    s = re.sub(r"\\textbf\{([^}]*)\}", r"\1", s)
    # Strip \overline{}
    s = re.sub(r"\\overline\{([^}]*)\}", r"\1", s)
    # Normalize shorthand: 0.5 → \frac{1}{2} etc. (skip for now — too complex)
    return s.strip()


def sympy_equivalent(expr1_str, expr2_str, timeout=60):
    """Check if two LaTeX expressions are symbolically equivalent via SymPy."""
    try:
        import sympy
        from sympy.parsing.latex import parse_latex
    except ImportError:
        return None  # SymPy not available

    try:
        # Try parsing both expressions
        parsed1 = parse_latex(expr1_str)
        parsed2 = parse_latex(expr2_str)

        # Simplify the difference
        diff = sympy.simplify(parsed1 - parsed2)
        if diff == 0:
            return True
        # Check numeric closeness
        try:
            numeric = complex(diff)
            if abs(numeric) < 0.001:
                return True
        except (TypeError, ValueError):
            pass
        return False
    except Exception:
        return None  # Parse failure — fall back to string comparison


def score_amps_hard(response, ground_truth):
    """Score AMPS_Hard math problems.

    Ground truth: LaTeX expression (e.g., "4 i \\sqrt{5}").
    Scoring: SymPy symbolic equivalence, fallback to normalized string match. Binary 0/1.
    """
    # Normalize ground truth
    gt_normalized = normalize_latex_answer(ground_truth)
    gt_for_sympy = ground_truth.strip()

    # Extraction cascade
    extracted = None

    # 1. Last \boxed{} → normalize via Minerva method
    boxed = extract_boxed(response)
    if boxed:
        extracted = normalize_final_answer(boxed)

    # 2. Last $ $ or $$ $$ block on last line
    if not extracted:
        lines = response.strip().split("\n")
        last_line = lines[-1] if lines else ""
        # Try $$ ... $$
        dd_matches = re.findall(r"\$\$(.*?)\$\$", last_line)
        if dd_matches:
            extracted = normalize_final_answer(dd_matches[-1])
        else:
            # Try $ ... $
            s_matches = re.findall(r"\$([^$]+)\$", last_line)
            if s_matches:
                extracted = normalize_final_answer(s_matches[-1])

    # 3. Check if ground truth appears in response tail
    if not extracted:
        tail = response[-200:] if len(response) > 200 else response
        if gt_normalized and gt_normalized in normalize_latex_answer(tail):
            return 1.0

    if not extracted:
        return 0.0

    # Normalize extracted answer
    extracted_normalized = normalize_latex_answer(extracted)

    # String comparison first (fast)
    if extracted_normalized == gt_normalized:
        return 1.0

    # SymPy symbolic equivalence
    result = sympy_equivalent(extracted, gt_for_sympy)
    if result is True:
        return 1.0
    # Also try normalized versions
    if result is None or result is False:
        result2 = sympy_equivalent(extracted_normalized, gt_normalized)
        if result2 is True:
            return 1.0

    return 0.0


# ---------------------------------------------------------------------------
# Math competitions scoring (AMC letter + AIME numeric)
# ---------------------------------------------------------------------------

def extract_answer_value(question_text, letter):
    """Extract the actual answer value for a given letter from the question text.

    Looks for patterns like \\textbf{(D)}~value or (D) value in the question.
    """
    if not question_text or not letter:
        return None
    # Try LaTeX format: \textbf{(X)} or \textbf{(X)}\~
    pattern = r"\\textbf\{\(" + re.escape(letter) + r"\)\}\s*[~\s]*(.+?)(?:\\textbf|\((?:[A-E])\)|$)"
    m = re.search(pattern, question_text)
    if m:
        return m.group(1).strip().rstrip("\\").strip()
    # Try plain format: (X) value
    pattern = r"\(" + re.escape(letter) + r"\)\s+(.+?)(?:\([A-E]\)|$)"
    m = re.search(pattern, question_text)
    if m:
        return m.group(1).strip()
    return None


def score_math_comp_amc(response, ground_truth, question_text=None):
    """Score AMC/SMC multiple-choice math competition.

    Ground truth: single letter A-E.
    Extraction cascade: solution tags → repeated letter → boxed → answer value → last line.
    Binary 0/1.
    """
    gt = ground_truth.strip().upper()
    if not gt or len(gt) != 1:
        return 0.0

    # 1. <solution> tags — check for repeated single char
    sol = extract_solution_tags(response)
    if sol:
        cleaned = sol.strip().replace(" ", "")
        if cleaned and len(set(cleaned.upper())) == 1 and cleaned[0].upper() == gt:
            return 1.0

    # 2. Repeated letter: ground_truth * 4 anywhere in response
    if gt * 4 in response.upper():
        return 1.0

    # 3. Last \boxed{} → single letter
    boxed = extract_boxed(response)
    if boxed:
        cleaned = boxed.strip().strip("\\").strip()
        if cleaned.upper() == gt:
            return 1.0
        # Check if it's \text{X} or similar
        m = re.match(r"[A-E]", cleaned.upper())
        if m and m.group() == gt:
            return 1.0

    # 4. Answer value matching (if question text provided)
    if question_text:
        value = extract_answer_value(question_text, gt)
        if value:
            # Check if this value appears in the tail of the response
            tail_len = 20 + len(value)
            tail = response[-tail_len:] if len(response) > tail_len else response
            if value in tail:
                return 1.0

    # 5. Last line check
    lines = [l.strip() for l in response.strip().split("\n") if l.strip()]
    if lines:
        last = lines[-1].strip().strip("*").strip()
        if last.upper() == gt:
            return 1.0
        # Check for (X) format
        m = re.search(r"\(([A-E])\)", last, re.IGNORECASE)
        if m and m.group(1).upper() == gt:
            return 1.0

    return 0.0


def score_math_comp_aime(response, ground_truth):
    """Score AIME numeric math competition.

    Ground truth: numeric string (e.g., "025").
    Extraction cascade: solution tags → ground truth in last 50 chars.
    Binary 0/1.
    """
    gt = ground_truth.strip()

    # 1. <solution> tags — check for repeated char
    sol = extract_solution_tags(response)
    if sol:
        cleaned = sol.strip().replace(" ", "")
        if cleaned and len(set(cleaned)) == 1 and cleaned[0] == gt[0]:
            # Check if repeated char matches (e.g., "000" for gt "0")
            if gt in cleaned or cleaned.lstrip("0") == gt.lstrip("0"):
                return 1.0
        # Direct match
        if cleaned == gt or cleaned.lstrip("0") == gt.lstrip("0"):
            return 1.0
        # Try as integer comparison
        try:
            if int(cleaned) == int(gt):
                return 1.0
        except ValueError:
            pass

    # 2. Ground truth in last 50 chars
    tail = response[-50:] if len(response) > 50 else response
    if gt in tail:
        return 1.0
    # Also try without leading zeros
    try:
        gt_int = str(int(gt))
        if gt_int in tail:
            return 1.0
    except ValueError:
        pass

    return 0.0


def score_math_comp(response, ground_truth, question_text=None):
    """Dispatch math_comp scoring based on ground truth format."""
    gt = ground_truth.strip()
    # If single letter A-E → AMC format
    if len(gt) == 1 and gt.upper() in "ABCDE":
        return score_math_comp_amc(response, ground_truth, question_text)
    # Otherwise → AIME numeric format
    return score_math_comp_aime(response, ground_truth)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Score LiveBench math answers")
    parser.add_argument("--task", required=True,
                        help="Task type: olympiad, AMPS_Hard, math_comp")
    parser.add_argument("--response", required=True,
                        help="Path to file containing model response text")
    parser.add_argument("--ground-truth", default=None,
                        help="Ground truth answer string (inline)")
    parser.add_argument("--ground-truth-file", default=None,
                        help="Path to file containing ground truth (preferred over inline)")
    parser.add_argument("--question-text", default=None,
                        help="Path to file containing question text (for AMC value extraction)")
    args = parser.parse_args()

    # Read response
    try:
        with open(args.response) as f:
            response = f.read()
    except FileNotFoundError:
        print(json.dumps({"score": 0.0, "error": f"Response file not found: {args.response}"}))
        sys.exit(1)

    # Strip <think> tags
    response = strip_think_tags(response)

    # Read question text if provided
    question_text = None
    if args.question_text:
        try:
            with open(args.question_text) as f:
                question_text = f.read()
        except FileNotFoundError:
            pass

    # Get ground truth (prefer file, fall back to inline)
    if args.ground_truth_file:
        try:
            with open(args.ground_truth_file) as f:
                ground_truth = f.read().strip()
        except FileNotFoundError:
            print(json.dumps({"score": 0.0, "error": f"Ground truth file not found: {args.ground_truth_file}"}))
            sys.exit(1)
    elif args.ground_truth is not None:
        ground_truth = args.ground_truth
    else:
        print(json.dumps({"score": 0.0, "error": "Must provide --ground-truth or --ground-truth-file"}))
        sys.exit(1)

    # Dispatch by task
    if args.task == "olympiad":
        score = score_olympiad(response, ground_truth)
    elif args.task == "AMPS_Hard":
        score = score_amps_hard(response, ground_truth)
    elif args.task == "math_comp":
        score = score_math_comp(response, ground_truth, question_text)
    else:
        print(json.dumps({"score": 0.0, "error": f"Unknown math task: {args.task}"}))
        sys.exit(1)

    print(json.dumps({"score": round(score, 4)}))


if __name__ == "__main__":
    main()
