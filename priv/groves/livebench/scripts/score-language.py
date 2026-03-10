#!/usr/bin/env python3
"""Score language (writing) answers for LiveBench.

Adapted from official LiveBench evaluation code:
  https://github.com/LiveBench/LiveBench/tree/main/livebench/process_results/writing

Task-specific scoring:
  - connections:       Group-based set comparison. Partial credit per group.
  - plot_unscrambling: Sentence ordering via Levenshtein edit distance. Partial credit.
  - typos:             Substring containment check. Binary 0/1.

Usage:
    score-language.py --task TASK --response FILE --ground-truth-file GT

Returns JSON to stdout: {"score": 0.0-1.0}
"""
import argparse
import difflib
import json
import re
import sys


def strip_think_tags(text):
    """Remove <think>...</think> blocks."""
    return re.sub(r"<think>.*?</think>", "", text, flags=re.DOTALL)


# ---------------------------------------------------------------------------
# Shared: \boxed{} extraction (matches LiveBench util.py)
# ---------------------------------------------------------------------------

def last_boxed_only_string(string):
    """Find the last \\boxed{...} in string. Matches official util.py."""
    idx = string.rfind("\\boxed")

    if "\\boxed " in string:
        return "\\boxed " + string.split("\\boxed ")[-1].split("$")[0]
    if idx < 0:
        idx = string.rfind("\\fbox")
        if idx < 0:
            return None

    i = idx
    right_brace_idx = None
    num_left_braces_open = 0
    while i < len(string):
        if string[i] == "{":
            num_left_braces_open += 1
        if string[i] == "}":
            num_left_braces_open -= 1
            if num_left_braces_open == 0:
                right_brace_idx = i
                break
        i += 1

    if right_brace_idx is None:
        retval = None
    else:
        retval = string[idx:right_brace_idx + 1].replace("$", "").replace("fbox", "boxed")

    return retval


def remove_boxed(s):
    """Remove \\boxed{} wrapper, return contents. Matches official util.py."""
    if "\\boxed " in s:
        left = "\\boxed "
        assert s[:len(left)] == left
        return s[len(left):]

    left = "\\boxed{"

    assert s[:len(left)] == left
    assert s[-1] == "}"

    return s[len(left):-1]


def levenshtein_distance(A, B):
    """Compute Levenshtein edit distance between two sequences.
    Matches official plot_unscrambling implementation."""
    N, M = len(A), len(B)
    dp = [[0 for _i in range(M + 1)] for _j in range(N + 1)]

    for j in range(M + 1):
        dp[0][j] = j
    for i in range(N + 1):
        dp[i][0] = i

    for i in range(1, N + 1):
        for j in range(1, M + 1):
            if A[i - 1] == B[j - 1]:
                dp[i][j] = dp[i - 1][j - 1]
            else:
                dp[i][j] = 1 + min(
                    dp[i - 1][j],
                    dp[i][j - 1],
                    dp[i - 1][j - 1]
                )

    return dp[N][M]


# ---------------------------------------------------------------------------
# Connections scoring (matches official writing/connections/utils.py)
# For release >= 2024-11-25: connections_process_results
# ---------------------------------------------------------------------------

def group_words(words):
    """Group words into sets of 4. Matches official."""
    groups = [set()]
    words = [w.strip().lower() for w in words]
    for word in words:
        if len(groups[-1]) == 4:
            groups.append(set())
        groups[-1].add(word)
    return groups


def connections_process_results_old(response, ground_truth):
    """Score Connections using bold-text extraction.
    Matches official connections_process_results_old (for older formats).

    Used as fallback when <solution> tags are not found.
    """
    llm_answer = response
    ground_truth_groups = group_words(ground_truth.split(','))

    # Extract bold words
    bold_words = re.findall(r'\*\*(.*?)\*\*', llm_answer.replace('\n', ''))

    if not bold_words:
        return 0.0

    bold_words_split = [words.split(',') for words in bold_words]

    max_score = 0
    for output_groups in [group_words(bw) for bw in bold_words_split]:
        correct_groups = 0
        for gt_group in ground_truth_groups:
            for out_group in output_groups:
                if all(word in out_group for word in gt_group):
                    correct_groups += 1
                    break
        denom = len(ground_truth_groups)
        if denom > 0:
            max_score = max(max_score, correct_groups / denom)

    return round(max_score, 4)


def score_connections(response, ground_truth):
    """Score Connections puzzle. Matches official connections_process_results.

    Extraction cascade (official for release >= 2024-11-25):
    1. <solution> tags (4 regex attempts: with/without newlines, normal/malformed)
    2. \\boxed{} fallback
    3. If nothing found, fall back to bold-text extraction (old method)

    Groups compared as SETS (order within group doesn't matter).
    Score = correct_groups / total_groups. Partial credit.
    """
    llm_answer = response
    ground_truth_words = ground_truth.split(',')

    # Extract from <solution> tags — 4 attempts matching official
    solution_matches = re.findall(r'<solution>(.*?)</solution>', llm_answer)
    if len(solution_matches) == 0:
        solution_matches = re.findall(r'<solution>(.*?)</solution>', llm_answer.replace('\n', ''))
    if len(solution_matches) == 0:
        solution_matches = re.findall(r'</solution>(.*?)</solution>', llm_answer)
    if len(solution_matches) == 0:
        solution_matches = re.findall(r'</solution>(.*?)</solution>', llm_answer.replace('\n', ''))

    # Fallback to \boxed{}
    if len(solution_matches) == 0 and '\\boxed' in llm_answer:
        boxed = last_boxed_only_string(llm_answer)
        if boxed:
            try:
                no_box = remove_boxed(boxed)
                solution_matches = [no_box.replace('\\text{', '').replace('}', '').replace('\\', '')]
            except (AssertionError, Exception):
                pass

    # Strip newlines from solution matches (official does this)
    solution_matches = [match.replace('\n', '') for match in solution_matches]

    # If nothing found via solution/boxed, fall back to bold-text extraction
    if len(solution_matches) == 0:
        return connections_process_results_old(response, ground_truth)

    # Handle multiple solution matches: combine and take last N words
    if len(solution_matches) > 1:
        all_words = []
        num_words = len(ground_truth_words)
        for match in solution_matches:
            all_words.extend(match.split(','))
        solution_words = all_words[-num_words:]
    else:
        solution_words = solution_matches[-1].split(',')

    # Group into sets of 4
    llm_groups = group_words(solution_words)
    ground_truth_groups = group_words(ground_truth_words)

    # Compare: official uses simple `in` check (no dedup tracking)
    correct_groups = 0
    for llm_group in llm_groups:
        if llm_group in ground_truth_groups:
            correct_groups += 1

    if len(ground_truth_groups) == 0:
        return 0.0

    return round(correct_groups / len(ground_truth_groups), 4)


# ---------------------------------------------------------------------------
# Plot Unscrambling scoring (matches official writing/plot_unscrambling/utils.py)
# ---------------------------------------------------------------------------

def extract_plot_summary(text):
    """Extract from <PLOT_SUMMARY> tags. Matches official."""
    # Greedy (.*) to capture everything between first opening and last closing
    pattern = r'<PLOT_SUMMARY>(.*)</PLOT_SUMMARY>'
    match = re.search(pattern, text, re.DOTALL)
    if not match:
        # Fallback: no closing tag, capture everything after opening
        pattern = r'<PLOT_SUMMARY>(.*)'
        match = re.search(pattern, text, re.DOTALL)
    return match.group(1) if match else text


def score_plot_unscrambling(response, ground_truth):
    """Score plot unscrambling. Matches official plot_unscrambling_process_results.

    Extraction: <PLOT_SUMMARY> tags, fallback to full response.
    Scoring: Levenshtein edit distance on sentence ordering. Partial credit.
    """
    llm_answer = extract_plot_summary(response)

    gt_sentences = [s.strip() for s in ground_truth.split('.')]
    ans_sentences = [s.strip() for s in llm_answer.split('.')
                     if s.strip() != '</PLOT_SUMMARY>'
                     and s.strip() != '**End of Plot Summary**']

    # Remove empty sentences
    gt_sentences = [s for s in gt_sentences if s]
    ans_sentences = [s for s in ans_sentences if s]

    if not gt_sentences:
        return 0.0

    # For each GT sentence, find best fuzzy match in answer sentences
    # Official uses cutoff=0.0 — ALWAYS finds a match
    ans_ordering = []
    for x in gt_sentences:
        best_match = difflib.get_close_matches(x, ans_sentences, n=1, cutoff=0.0)
        if best_match:
            ans_ordering.append(ans_sentences.index(best_match[0]))

    n_sentences_gt = len(gt_sentences)
    raw_distance = levenshtein_distance(list(range(len(gt_sentences))), ans_ordering)
    score = 1 - (raw_distance / n_sentences_gt)

    # Official does NOT clamp to 0 — score can be negative
    return round(score, 4)


# ---------------------------------------------------------------------------
# Typos scoring (matches official writing/typos/utils.py)
# ---------------------------------------------------------------------------

def extract_answer_typos(llm_answer):
    """Extract from --- delimiters. Matches official extract_answer."""
    pattern = r'.* --- (.*?) --- .*'
    match = re.search(pattern, llm_answer)
    return match.group(1) if match else llm_answer


def score_typos(response, ground_truth):
    """Score typos correction. Matches official typos_process_results.

    Extraction:
    1. <solution> tags (WITHOUT re.DOTALL — official behavior)
    2. Strip stray tags, try --- delimiters, else full response

    Critical: newline normalization applied before comparison.
    Score: 1.0 if ground_truth is substring of parsed answer, else 0.0.
    """
    parsed_answer = None

    # 1. <solution> tags — official does NOT use re.DOTALL
    solution_matches = re.findall(r'<solution>(.*?)</solution>', response)
    if len(solution_matches) > 0:
        parsed_answer = solution_matches[-1]
    else:
        # Strip stray solution tags, then try --- extraction
        parsed_answer = response.replace('<solution>', '').replace('</solution>', '')
        parsed_answer = extract_answer_typos(parsed_answer)

    # Newline normalization (matches official behavior)
    parsed_answer = ' '.join(list(filter(None, parsed_answer.strip().split('\n'))))

    if ground_truth in parsed_answer:
        return 1.0

    return 0.0


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Score LiveBench language answers")
    parser.add_argument("--task", required=True,
                        help="Task type: connections, plot_unscrambling, typos")
    parser.add_argument("--response", required=True,
                        help="Path to file containing model response text")
    parser.add_argument("--ground-truth", default=None,
                        help="Ground truth answer string (inline)")
    parser.add_argument("--ground-truth-file", default=None,
                        help="Path to file containing ground truth (preferred over inline)")
    args = parser.parse_args()

    try:
        with open(args.response) as f:
            response = f.read()
    except FileNotFoundError:
        print(json.dumps({"score": 0.0, "error": f"Response file not found: {args.response}"}))
        sys.exit(1)

    response = strip_think_tags(response)

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

    if args.task == "connections":
        score = score_connections(response, ground_truth)
    elif args.task == "plot_unscrambling":
        score = score_plot_unscrambling(response, ground_truth)
    elif args.task == "typos":
        score = score_typos(response, ground_truth)
    else:
        print(json.dumps({"score": 0.0, "error": f"Unknown language task: {args.task}"}))
        sys.exit(1)

    print(json.dumps({"score": round(score, 4)}))


if __name__ == "__main__":
    main()
