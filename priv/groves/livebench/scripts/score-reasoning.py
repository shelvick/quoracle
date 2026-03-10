#!/usr/bin/env python3
"""Score reasoning answers for LiveBench.

Adapted from official LiveBench evaluation code:
  https://github.com/LiveBench/LiveBench/tree/main/livebench/process_results/reasoning

Task-specific scoring:
  - spatial:         Bold word extraction, word-to-number, fuzzy shape match. Binary 0/1.
  - web_of_lies_v2:  yes/no/unknown triplet extraction. Binary 0/1.
  - zebra_puzzle:    Solution tag extraction, ALWAYS partial credit.

Usage:
    score-reasoning.py --task TASK --response FILE --ground-truth-file GT

Returns JSON to stdout: {"score": 0.0-1.0}
"""
import argparse
import json
import re
import sys
from itertools import product


def strip_think_tags(text):
    """Remove <think>...</think> blocks."""
    return re.sub(r"<think>.*?</think>", "", text, flags=re.DOTALL)


# ---------------------------------------------------------------------------
# Shared: \boxed{} extraction (matches LiveBench util.py)
# ---------------------------------------------------------------------------

def last_boxed_only_string(s):
    """Find the last \\boxed{...} in string."""
    idx = s.rfind("\\boxed")
    if idx < 0:
        return None
    i = idx
    while i < len(s) and s[i] != '{':
        i += 1
    if i >= len(s):
        return None
    depth = 0
    start = i
    while i < len(s):
        if s[i] == '{':
            depth += 1
        elif s[i] == '}':
            depth -= 1
            if depth == 0:
                return s[idx:i + 1]
        i += 1
    return None


def remove_boxed(s):
    """Remove \\boxed{} wrapper, return contents."""
    if s is None:
        return ""
    idx = s.find('{')
    if idx < 0:
        return s
    return s[idx + 1:-1] if s.endswith('}') else s[idx + 1:]


def extract_solution_tags(text):
    """Extract content from <solution>...</solution> tags (last match)."""
    matches = re.findall(r'<solution>(.*?)</solution>', text, re.DOTALL | re.IGNORECASE)
    if matches:
        return matches[-1].strip()
    # Try malformed: </solution>...<solution>
    matches = re.findall(r'</solution>(.*?)</solution>', text, re.DOTALL | re.IGNORECASE)
    if matches:
        return matches[-1].strip()
    return None


# ---------------------------------------------------------------------------
# Spatial scoring (matches official spatial/utils.py)
# ---------------------------------------------------------------------------

WORD_TO_NUMBER = {
    "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4",
    "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9",
    "ten": "10", "eleven": "11", "twelve": "12", "thirteen": "13",
    "fourteen": "14", "fifteen": "15", "sixteen": "16", "seventeen": "17",
    "eighteen": "18", "nineteen": "19", "twenty": "20",
}

# Official hardcoded shapes for fuzzy matching
_FUZZY_SHAPES = ["tetrahedra", "tetrahedron", "triangle", "square"]


def score_spatial(response, ground_truth):
    """Score spatial reasoning. Binary 0/1.

    Official logic:
    1. Exact match
    2. Extract last 3 bold words (**word**), check each
    3. Word-to-number conversion
    4. Fuzzy shape match (hardcoded list, unidirectional)
    5. \\boxed{} extraction
    NO <solution> tag check (official doesn't use it).
    """
    gt = ground_truth.strip().lower()

    # Exact match
    if response == ground_truth:
        return 1.0

    # Extract bold words — official uses \*\*([^\*]+)\*\* (no triple-asterisk)
    bold_words = re.findall(r'\*\*([^\*]+)\*\*', response)

    score = 0

    # Check last 3 bold words
    words_to_check = []
    for i in range(3):
        if bold_words and len(bold_words) > i:
            words_to_check.append(bold_words[-i - 1].strip().lower())

    for word in words_to_check:
        # Direct match
        if word == gt:
            score = 1

        # Word-to-number: convert LLM's word to number, compare with GT
        if word in WORD_TO_NUMBER and WORD_TO_NUMBER[word] == gt:
            score = 1

        # Fuzzy shape matching (official: hardcoded list, unidirectional)
        for shape in _FUZZY_SHAPES:
            if gt == shape and shape in word and len(word) < (2 * len(shape) + 5):
                score = 1

    # Boxed extraction
    if score == 0:
        llm_text = response.replace("\\\\fbox{", "\\\\boxed{")
        last_boxed = last_boxed_only_string(llm_text)
        if last_boxed:
            parsed = remove_boxed(last_boxed)
            parsed = parsed.replace("\\textbf{", "")
            parsed = parsed.replace("\\mathbf{", "")
            parsed = parsed.replace("\\text{", "")
            parsed = parsed.replace("}", "")
            if parsed == ground_truth:
                score = 1

    return float(score)


# ---------------------------------------------------------------------------
# Web of Lies v2 scoring (matches official web_of_lies_v2/utils.py)
# ---------------------------------------------------------------------------

def score_web_of_lies_v2(response, ground_truth):
    """Score web_of_lies_v2. Binary 0/1.

    Official extraction cascade:
    1. <solution> tags → parse yes/no/unknown words
    2. Bold words → split into individual words, scan backward for 3 valid words
    3. \\boxed{} extraction
    4. Permutation scan (find last occurring triplet pattern)
    """
    gt = ground_truth.strip().lower()
    parsed_answer = None

    # 1. <solution> tags
    solution_matches = re.findall(r'<solution>(.*?)</solution>', response)
    if not solution_matches:
        solution_matches = re.findall(r'</solution>(.*?)</solution>', response)
    if solution_matches:
        parsed_answer = solution_matches[-1]

    # 2. Bold words — split each match into individual words, scan backward
    bold_matches = re.findall(r'\*\*(.*?)\*\*', response)
    if parsed_answer is None and bold_matches:
        # Split each bold match into individual words
        bold_words = [
            word.lower().strip().replace(',', '').replace('.', '')
            for match in bold_matches
            for word in match.split()
        ]
        collected = []
        i = len(bold_words) - 1
        while i >= 0 and len(collected) < 3:
            if bold_words[i] in ("yes", "no", "unknown"):
                collected.insert(0, bold_words[i])
            i -= 1
        if collected:
            parsed_answer = ", ".join(collected)

    # 3. \boxed{}
    if parsed_answer is None or (parsed_answer and not parsed_answer.strip()):
        llm_text = response.replace("\\\\boxed{\\\\textbf{", "\\\\boxed{")
        llm_text = llm_text.replace("\\\\fbox{", "\\\\boxed{")
        llm_text = llm_text.replace("\\textbf{", "\\boxed{")
        last_boxed = last_boxed_only_string(llm_text)
        if last_boxed:
            parsed_answer = remove_boxed(last_boxed)

    # 4. Permutation scan — find last occurring triplet pattern
    if parsed_answer is None:
        combs = product(["yes", "no", "unknown"], repeat=3)
        final_comb = None
        final_comb_index = -1
        for comb in combs:
            pattern = ", ".join(comb)
            index = response.lower().find(pattern)
            if index != -1 and index > final_comb_index:
                final_comb = comb
                final_comb_index = index
        if final_comb is not None:
            parsed_answer = ", ".join(final_comb)

    # Compare
    if parsed_answer and parsed_answer == gt:
        return 1.0

    # Containment check: if parsed_answer has exactly 3 valid words and GT is contained
    if parsed_answer:
        valid_count = parsed_answer.count("yes") + parsed_answer.count("no") + parsed_answer.count("unknown")
        if valid_count == 3 and gt in parsed_answer:
            return 1.0

    return 0.0


# ---------------------------------------------------------------------------
# Zebra Puzzle scoring (matches official zebra_puzzle/utils.py)
# ---------------------------------------------------------------------------

def score_zebra_puzzle(response, ground_truth):
    """Score zebra puzzle. ALWAYS partial credit.

    Official formula (for ALL answers, single or multi-value):
        score = ((num_correct == total) + num_correct / total) / 2

    Ground truth is always comma-split.
    """
    gt_parts = ground_truth.split(',')

    # 1. <solution> tags
    solution_matches = re.findall(r'<solution>(.*?)</solution>', response)
    if not solution_matches:
        solution_matches = re.findall(r'</solution>(.*?)</solution>', response)

    # 2. \boxed{} fallback
    if not solution_matches:
        llm_text = response.replace("\\\\fbox{", "\\\\boxed{")
        last_boxed = last_boxed_only_string(llm_text)
        if last_boxed:
            boxed_removed = remove_boxed(last_boxed)
            boxed_removed = boxed_removed.replace("\\text{", "").replace("}", "").replace('\\', '')
            solution_matches.append(boxed_removed)

    # 3. Last line with matching comma count
    if not solution_matches:
        last_line = response.strip().split('\n')[-1]
        if last_line.count(',') == len(gt_parts) - 1:
            solution_matches.append(last_line)

    if not solution_matches:
        return 0.0

    # Handle multiple solution matches: combine and take last N
    if len(solution_matches) > 1:
        all_solution_text = []
        for match in solution_matches:
            all_solution_text += match.split(',')
        solution_text = all_solution_text[-len(gt_parts):]
    else:
        solution_text = solution_matches[-1].split(',')

    # Compare — ALWAYS partial credit
    num_correct = 0
    total = len(gt_parts)

    for i in range(total):
        gt_word = gt_parts[i].strip().lower().replace('-', ' ')
        if i >= len(solution_text):
            continue
        llm_word = solution_text[i].strip().lower().replace('-', ' ').replace('position', '')
        if gt_word == llm_word or gt_word in llm_word:
            num_correct += 1

    # Official formula: ((all_correct) + correct/total) / 2
    score = ((1 if num_correct == total else 0) + num_correct / total) / 2
    return round(score, 4)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Score LiveBench reasoning answers")
    parser.add_argument("--task", required=True,
                        help="Task type: spatial, web_of_lies_v2, zebra_puzzle")
    parser.add_argument("--response", required=True,
                        help="Path to file containing model response text")
    parser.add_argument("--ground-truth", default=None,
                        help="Ground truth answer string (inline)")
    parser.add_argument("--ground-truth-file", default=None,
                        help="Path to file containing ground truth")
    args = parser.parse_args()

    try:
        with open(args.response) as f:
            response = f.read()
    except FileNotFoundError:
        print(json.dumps({"score": 0.0, "error": f"Response file not found: {args.response}"}))
        sys.exit(1)

    response = strip_think_tags(response)

    # Get ground truth
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

    if args.task == "spatial":
        score = score_spatial(response, ground_truth)
    elif args.task == "web_of_lies_v2":
        score = score_web_of_lies_v2(response, ground_truth)
    elif args.task == "zebra_puzzle":
        score = score_zebra_puzzle(response, ground_truth)
    else:
        print(json.dumps({"score": 0.0, "error": f"Unknown reasoning task: {args.task}"}))
        sys.exit(1)

    print(json.dumps({"score": round(score, 4)}))


if __name__ == "__main__":
    main()
