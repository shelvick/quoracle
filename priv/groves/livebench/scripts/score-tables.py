#!/usr/bin/env python3
"""Score data_analysis answers for LiveBench.

Adapted from official LiveBench evaluation code:
  https://github.com/LiveBench/LiveBench/tree/main/livebench/process_results/data_analysis

Task-specific scoring:
  - cta:             Column type annotation — \boxed{} extraction, clean_text match. Binary 0/1.
  - tablereformat:   Table format conversion — pandas-based parsing, cell-by-cell comparison. Binary 0/1.
  - tablejoin:       Table join mapping — F1 score on key-value pairs. Partial credit.

Usage:
    python3 score-tables.py --task cta --response-file resp.txt --ground-truth-file gt.txt
    python3 score-tables.py --task tablereformat --response-file resp.txt --ground-truth-file gt.txt [--question-file q.txt]
    python3 score-tables.py --task tablejoin --response-file resp.txt --ground-truth-file gt.txt

Output: JSON to stdout  {"score": 0.0-1.0}
"""
import argparse
import json
import math
import re
import sys
from ast import literal_eval
from io import StringIO

# pandas required for tablereformat — available in ~/.quoracle/benchmarks/.venv
try:
    import pandas as pd
    from pandas.api.types import is_numeric_dtype
    HAS_PANDAS = True
except ImportError:
    HAS_PANDAS = False


def strip_think_tags(text):
    """Remove <think>...</think> blocks."""
    return re.sub(r"<think>.*?</think>", "", text, flags=re.DOTALL)


# ---------------------------------------------------------------------------
# Shared: \boxed{} extraction (matches LiveBench util.py)
# ---------------------------------------------------------------------------

def last_boxed_only_string(s):
    """Find the last \\boxed{...} in string, return full boxed expression."""
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


# ---------------------------------------------------------------------------
# CTA scoring (matches official cta/utils.py exactly)
# ---------------------------------------------------------------------------

def clean_text(text):
    """Normalize text: lowercase, strip, remove non-word chars."""
    text = text.lower().strip()
    text = re.sub(r'[^\w]', '', text)
    return text


def score_cta(response, ground_truth):
    """Score CTA answer. Binary 0/1.

    Official logic: extract from \\boxed{} if present, otherwise use raw response.
    Compare using clean_text(). Suffix match also accepted.

    Also extracts from <solution> tags if present.
    """
    parsed_answer = response

    # Extract from <solution> tags if present
    sol_matches = re.findall(r'<solution>(.*?)</solution>', parsed_answer, re.DOTALL)
    if sol_matches:
        parsed_answer = sol_matches[-1].strip()

    if '\\boxed{' in parsed_answer:
        boxed = last_boxed_only_string(parsed_answer)
        if boxed:
            parsed_answer = remove_boxed(boxed)
            parsed_answer = parsed_answer.replace('\\text{', '').replace('}', '').replace('\\', '')

    gt_clean = clean_text(ground_truth)
    ans_clean = clean_text(parsed_answer)

    if gt_clean == ans_clean:
        return 1.0
    if len(ans_clean) >= len(gt_clean) and ans_clean[-len(gt_clean):] == gt_clean:
        return 1.0
    return 0.0


# ---------------------------------------------------------------------------
# Tablejoin scoring (matches official tablejoin/utils.py exactly)
# ---------------------------------------------------------------------------

def clean_llm_output_tablejoin(s):
    """Parse LLM output into dict. Matches official clean_llm_output."""
    # <solution> tags (recursive)
    matches = re.findall(r'<solution>(.*?)</solution>', s, re.DOTALL)
    if matches:
        return clean_llm_output_tablejoin(matches[-1].strip())

    # Try literal_eval directly
    try:
        match_d = literal_eval(s)
    except Exception:
        # Try code fences
        matches = re.findall(r'```python(.*?)```', s.replace("\n", ""), re.MULTILINE)
        if not matches:
            matches = re.findall(r'```json(.*?)```', s.replace("\n", ""), re.MULTILINE)
        if not matches:
            matches = re.findall(r'```(.*?)```', s.replace("\n", ""), re.MULTILINE)
        if not matches:
            if '\\boxed' in s:
                boxed = last_boxed_only_string(s.replace('\n', ''))
                if boxed:
                    no_boxed = remove_boxed(boxed)
                    matches = [re.sub(r"\\text{[\'|\"](.*?)[\'|\"]}", r"'\1'", no_boxed).replace('\\', '')]
        if not matches:
            matches = [s]
        if len(matches) >= 1:
            matches = matches[-1]
        matches = matches.replace('null', 'None')
        try:
            match_d = literal_eval(matches)
        except Exception:
            return {}

    if not isinstance(match_d, dict):
        return {}

    # Remove None values (matches official)
    keys = list(match_d.keys())
    for k in keys:
        if match_d[k] is None:
            del match_d[k]
    return match_d


def score_tablejoin(response, ground_truth):
    """Score tablejoin using F1. Partial credit 0.0-1.0.

    Value mismatch counts as BOTH fp AND fn (matches official behavior).
    """
    # Parse ground truth
    if isinstance(ground_truth, str):
        try:
            gt_map = literal_eval(ground_truth)
        except Exception:
            try:
                gt_map = json.loads(ground_truth)
            except Exception:
                return 0.0
    else:
        gt_map = ground_truth

    if not isinstance(gt_map, dict):
        return 0.0

    # Parse LLM output
    llm_clean = clean_llm_output_tablejoin(response)
    if not llm_clean:
        return 0.0

    tp = 0
    fp = 0
    fn = 0

    for k, v in llm_clean.items():
        gt = gt_map.get(k, None)
        if not gt:
            fp += 1
        elif gt == v:
            tp += 1
        else:
            # Value mismatch: counts as BOTH false positive AND false negative
            fp += 1
            fn += 1

    for k, v in gt_map.items():
        llm_resp = llm_clean.get(k, None)
        if not llm_resp:
            fn += 1

    if tp == 0:
        return 0.0

    f1 = round((2 * tp) / ((2 * tp) + fp + fn), 2)
    return f1


# ---------------------------------------------------------------------------
# Tablereformat scoring (matches official tablereformat/utils.py)
# ---------------------------------------------------------------------------

def clean_llm_output_reformat(s):
    """Clean LLM output for tablereformat. Matches official clean_llm_output."""
    pattern_solution = r'<solution>(.*?)</solution>'
    matches = re.findall(pattern_solution, s, re.DOTALL)
    if matches:
        return clean_llm_output_reformat(matches[-1].strip())
    pattern_json = r'```json\n(.*?)```'
    matches = re.findall(pattern_json, s, re.DOTALL)
    if matches:
        return matches[-1].strip()
    pattern_html = r'```html\n(.*?)```'
    matches = re.findall(pattern_html, s, re.DOTALL)
    if matches:
        return matches[-1].strip()
    pattern_a = r'^```.*\n'
    s = re.sub(pattern_a, "", s)
    s = s.replace("&amp;", "&")
    return s.replace("```", "").strip()


def remove_initial_phrase(text):
    """Remove intro phrases like 'Here is the table in a new format:'."""
    pattern = r'^\s*(Here|Input)\b.*?\b(format|table)\s*[:)]\s*'
    modified_text = re.sub(pattern, '', text, flags=re.IGNORECASE)
    return modified_text.strip()


def read_df_func(df_type, df_str):
    """Read DataFrame from string in specified format (v1 parsing)."""
    if df_type == "json":
        for orient in ["index", "records", "table", "values"]:
            try:
                kwargs = {"orient": orient, "encoding": "utf-8"}
                if orient == "records":
                    # Try non-lines first, then lines
                    try:
                        return pd.read_json(StringIO(df_str), **kwargs)
                    except Exception:
                        return pd.read_json(StringIO(df_str), orient="records", lines=True, encoding="utf-8")
                return pd.read_json(StringIO(df_str), **kwargs)
            except Exception:
                continue
        raise ValueError("Could not read JSON in any orientation")
    elif df_type == "jsonl":
        return pd.read_json(StringIO(df_str), orient="records", lines=True, encoding="utf-8")
    elif df_type == "html":
        return pd.concat(pd.read_html(StringIO(df_str), encoding="utf-8"), axis=0)
    elif df_type == "csv":
        return pd.read_csv(StringIO(df_str), encoding="utf-8")
    elif df_type == "markdown":
        return pd.read_table(StringIO(df_str), sep="|", header=0, index_col=1, skipinitialspace=True)
    elif df_type == "tsv":
        return pd.read_csv(StringIO(df_str), sep='\t', encoding="utf-8")
    raise ValueError(f"Unsupported format: {df_type}")


def read_df_func_v2(df_type, df_str):
    """Read DataFrame from string in specified format (v2 parsing)."""
    if df_type == "json":
        try:
            return pd.read_json(StringIO(df_str), orient="table", encoding="utf-8")
        except Exception:
            try:
                return pd.read_json(StringIO(df_str), orient="index", lines=False, encoding="utf-8")
            except Exception:
                try:
                    return pd.read_json(StringIO(df_str), orient="records", lines=False, encoding="utf-8")
                except Exception:
                    return None
    elif df_type == "jsonl":
        return pd.read_json(StringIO(df_str), orient="records", lines=True, encoding="utf-8")
    elif df_type == "html":
        return pd.concat(pd.read_html(StringIO(df_str), encoding="utf-8"), axis=0)
    elif df_type == "csv":
        return pd.read_csv(StringIO(df_str), encoding="utf-8")
    elif df_type == "markdown":
        lines = df_str.strip().split("\n")
        header = lines[0]
        data_lines = lines[2:] if len(lines) > 2 else []
        processed_md = header + "\n" + "\n".join(data_lines)
        df = pd.read_table(StringIO(processed_md), sep="|", header=0, skipinitialspace=True).iloc[:, 1:-1]
        for col in df.columns:
            if df[col].dtype == 'object':
                df[col] = df[col].astype(str).str.strip()
        return df
    elif df_type == "tsv":
        return pd.read_csv(StringIO(df_str), sep='\t', encoding="utf-8")
    raise ValueError(f"Unsupported format: {df_type}")


def read_sep_table_from_text(text, header, sep=','):
    """Fallback: extract CSV/TSV table from text by finding header line."""
    text = text.strip()
    lines = text.split('\n')
    header_line = 0
    while header_line < len(lines) and lines[header_line].strip() != header.strip():
        header_line += 1
    if header_line == len(lines) or lines[header_line].strip() != header.strip():
        return None
    table = lines[header_line:]
    parsed_table = None
    while parsed_table is None and table:
        try:
            parsed_table = pd.read_csv(StringIO('\n'.join(table)), sep=sep)
        except Exception:
            table = table[:-1]
    return parsed_table


def read_jsonl_table_from_text(text, header):
    """Fallback: extract JSONL records from text."""
    lines = text.strip().split('\n')
    table = []
    for line in lines:
        if len(line) < 2 or line[0] != '{' or line[-1] != '}':
            continue
        if not all(key in line for key in header):
            continue
        try:
            table.append(json.loads(line))
        except Exception:
            continue
    if not table:
        return None
    return pd.DataFrame(table)


def detect_output_format(question_text):
    """Detect output format and version from question text."""
    # v1: "Please convert the Input Table from X format to Y format"
    m = re.search(r'Please convert the Input Table from \w+ format to (\w+) format', question_text, re.IGNORECASE)
    if m:
        return m.group(1).lower(), "v1"

    # v2: "Target Format: X"
    m = re.search(r'Target Format:\s*(\w+)', question_text)
    if m:
        return m.group(1).lower(), "v2"

    return None, None


def auto_detect_format(text):
    """Try to auto-detect the format of a table string."""
    text = text.strip()
    if not text:
        return None, None

    # JSON (starts with { or [)
    if text[0] in ('{', '['):
        try:
            pd.read_json(StringIO(text), orient="records", encoding="utf-8")
            return "json", None
        except Exception:
            pass
        try:
            pd.read_json(StringIO(text), orient="index", encoding="utf-8")
            return "json", None
        except Exception:
            pass

    # JSONL (multiple lines starting with {)
    lines = text.split('\n')
    if len(lines) > 1 and all(l.strip().startswith('{') for l in lines[:3] if l.strip()):
        return "jsonl", None

    # HTML
    if '<table' in text.lower() or '<tr' in text.lower():
        return "html", None

    # Markdown (lines with |)
    if '|' in lines[0] and len(lines) > 1:
        return "markdown", None

    # TSV (tabs in first line)
    if '\t' in lines[0]:
        return "tsv", None

    # CSV (commas, multiple lines)
    if ',' in lines[0] and len(lines) > 1:
        return "csv", None

    return None, None


def check_table_reformat(output_format, llm_df, gt_df):
    """Compare two DataFrames cell-by-cell. Matches official check_table_reformat."""
    try:
        gt_df.columns = [s.strip() for s in gt_df.columns]
        if 'index' in gt_df.columns:
            gt_df = gt_df.drop(columns=['index'])
        llm_df.columns = [s.strip() for s in llm_df.columns]
        if 'index' in llm_df.columns:
            llm_df = llm_df.drop(columns=['index'])

        assert len(llm_df) == len(gt_df), \
            f"Row count mismatch: {len(llm_df)} vs {len(gt_df)}"
        assert list(sorted(llm_df.columns)) == list(sorted(gt_df.columns)), \
            f"Column mismatch: {sorted(llm_df.columns)} vs {sorted(gt_df.columns)}"

        for i in range(len(llm_df)):
            for key in llm_df.columns:
                llm_val = llm_df.iloc[i][key]
                gt_val = gt_df.iloc[i][key]

                if isinstance(llm_val, str):
                    llm_val = llm_val.strip()
                if isinstance(gt_val, str):
                    gt_val = gt_val.strip()

                both_numeric = (
                    (isinstance(llm_val, (int, float)) or is_numeric_dtype(type(llm_val)))
                    and (isinstance(gt_val, (int, float)) or is_numeric_dtype(type(gt_val)))
                )

                if both_numeric:
                    try:
                        llm_f = float(llm_val)
                        gt_f = float(gt_val)
                    except (ValueError, TypeError):
                        assert str(llm_val).strip() == str(gt_val).strip()
                        continue
                    if math.isnan(llm_f) and math.isnan(gt_f):
                        continue
                    assert abs(llm_f - gt_f) < 1e-6
                else:
                    assert llm_val == gt_val

    except AssertionError:
        return 0
    except Exception:
        return 0
    return 1


def score_tablereformat(response, ground_truth, question_text=None):
    """Score tablereformat. Binary 0/1.

    Matches official table_process_results logic:
    1. Determine output format from question text
    2. Parse ground truth and response using format-specific pandas readers
    3. Compare cell-by-cell
    """
    if not HAS_PANDAS:
        return 0.0

    # Determine output format
    output_format = None
    version = "v1"

    if question_text:
        output_format, version = detect_output_format(question_text)

    if not output_format:
        output_format, _ = auto_detect_format(ground_truth)
        if not version:
            version = "v1"

    if not output_format:
        # Last resort: try all formats
        for fmt in ["json", "jsonl", "csv", "tsv", "markdown", "html"]:
            try:
                df_read = read_df_func if version == "v1" else read_df_func_v2
                gt_df = df_read(fmt, ground_truth)
                if gt_df is not None and len(gt_df) > 0:
                    output_format = fmt
                    break
            except Exception:
                continue

    if not output_format:
        return 0.0

    df_read = read_df_func if version == "v1" else read_df_func_v2

    # Parse ground truth
    try:
        gt_df = df_read(output_format, ground_truth)
    except Exception:
        return 0.0

    if gt_df is None:
        return 0.0

    # Parse LLM output
    llm_clean = clean_llm_output_reformat(response)
    llm_clean = remove_initial_phrase(llm_clean)

    llm_df = None
    try:
        llm_df = df_read(output_format, llm_clean)
    except Exception:
        # Fallback: try extracting table from text
        if output_format in ('csv', 'tsv'):
            sep = ',' if output_format == 'csv' else '\t'
            header = sep.join(gt_df.columns)
            llm_df = read_sep_table_from_text(llm_clean, header, sep=sep)
        elif output_format == 'jsonl':
            llm_df = read_jsonl_table_from_text(llm_clean, gt_df.columns)

    if llm_df is None:
        return 0.0

    score = check_table_reformat(output_format, llm_df, gt_df)

    if score == 0:
        # Retry: try extracting table directly from text
        if output_format == 'csv':
            header = ','.join(gt_df.columns)
            retry_df = read_sep_table_from_text(llm_clean, header, sep=',')
        elif output_format == 'tsv':
            header = '\t'.join(gt_df.columns)
            retry_df = read_sep_table_from_text(llm_clean, header, sep='\t')
        elif output_format == 'jsonl':
            retry_df = read_jsonl_table_from_text(llm_clean, gt_df.columns)
        else:
            retry_df = None

        if retry_df is not None:
            score = check_table_reformat(output_format, retry_df, gt_df)

    return float(score)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description='Score LiveBench data_analysis answers')
    parser.add_argument('--task', required=True, choices=['cta', 'tablereformat', 'tablejoin'])
    parser.add_argument('--response', help='Response text (inline)')
    parser.add_argument('--response-file', help='Path to response text file')
    parser.add_argument('--ground-truth', help='Ground truth text (inline)')
    parser.add_argument('--ground-truth-file', help='Path to ground truth text file')
    parser.add_argument('--question-file', help='Path to question text file (for tablereformat format detection)')
    args = parser.parse_args()

    # Load response
    if args.response_file:
        try:
            with open(args.response_file) as f:
                response = f.read()
        except FileNotFoundError:
            print(json.dumps({"score": 0.0, "error": f"Response file not found: {args.response_file}"}))
            sys.exit(1)
    elif args.response:
        response = args.response
    else:
        print(json.dumps({"score": 0.0, "error": "no response provided"}))
        sys.exit(1)

    # Load ground truth
    if args.ground_truth_file:
        try:
            with open(args.ground_truth_file) as f:
                ground_truth = f.read().strip()
        except FileNotFoundError:
            print(json.dumps({"score": 0.0, "error": f"Ground truth file not found: {args.ground_truth_file}"}))
            sys.exit(1)
    elif args.ground_truth:
        ground_truth = args.ground_truth
    else:
        print(json.dumps({"score": 0.0, "error": "no ground truth provided"}))
        sys.exit(1)

    # Load question text (optional, for tablereformat)
    question_text = None
    if args.question_file:
        try:
            with open(args.question_file) as f:
                question_text = f.read()
        except FileNotFoundError:
            pass

    # Strip <think> tags
    response = strip_think_tags(response)

    # Score
    if args.task == 'cta':
        score = score_cta(response, ground_truth)
    elif args.task == 'tablereformat':
        score = score_tablereformat(response, ground_truth, question_text)
    elif args.task == 'tablejoin':
        score = score_tablejoin(response, ground_truth)
    else:
        score = 0.0

    print(json.dumps({"score": round(score, 4)}))


if __name__ == '__main__':
    main()
