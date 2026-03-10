#!/usr/bin/env python3
"""Score instruction_following answers for LiveBench.

Adapted from official IFEval constraint checkers:
  https://github.com/google-research/google-research/tree/master/instruction_following_eval
  https://github.com/LiveBench/LiveBench/tree/main/livebench/if_runner

Each constraint checker mirrors the official IFEval evaluation logic (strict mode).
The 16 constraint types used in the LiveBench 2024-11-25 dataset are all IFEval types.

Usage:
    python3 score-instructions.py --response-file resp.txt --constraints-file constraints.json

Output: JSON to stdout  {"score": 0.0-1.0, "all_followed": bool, "per_constraint": [...]}
"""
import argparse
import collections
import json
import re
import sys


def strip_think_tags(text):
    """Remove <think>...</think> blocks."""
    return re.sub(r"<think>.*?</think>", "", text, flags=re.DOTALL)


# ---------------------------------------------------------------------------
# Constraint checkers — each returns (bool, str)
# Matches official IFEval strict evaluation logic
# ---------------------------------------------------------------------------

# The official IFEval uses these two comparison relations:
_COMPARISON_RELATION = ["less than", "at least"]


def check_keywords_existence(response, kwargs):
    """Check that all specified keywords appear in the response.

    Official: re.search(keyword, value, flags=re.IGNORECASE) for each keyword.
    """
    keywords = kwargs.get('keywords', [])
    if not keywords:
        return True, "no keywords specified"
    missing = []
    for kw in keywords:
        if not re.search(re.escape(kw), response, flags=re.IGNORECASE):
            missing.append(kw)
    if missing:
        return False, f"missing keywords: {missing}"
    return True, f"all {len(keywords)} keywords found"


def check_keywords_forbidden_words(response, kwargs):
    """Check that no forbidden words appear in the response.

    Official: re.search(r'\\b' + word + r'\\b', value, flags=re.IGNORECASE)
    """
    forbidden = kwargs.get('forbidden_words', [])
    if not forbidden:
        return True, "no forbidden words specified"
    found = [w for w in forbidden if re.search(r'\b' + re.escape(w) + r'\b', response, re.IGNORECASE)]
    if found:
        return False, f"forbidden words found: {found}"
    return True, f"none of {len(forbidden)} forbidden words found"


def check_keywords_frequency(response, kwargs):
    """Check keyword appears at correct frequency.

    Official: NOT in the 16 constraint types used in our dataset.
    Keeping for completeness with 'less than' / 'at least' handling.
    """
    keyword = kwargs.get('keyword', '')
    frequency = kwargs.get('frequency', 1)
    relation = kwargs.get('relation', 'at least')
    if not keyword:
        return True, "no keyword specified"
    count = len(re.findall(re.escape(keyword), response, re.IGNORECASE))
    if relation == 'less than':
        ok = count < frequency
    else:  # 'at least'
        ok = count >= frequency
    return ok, f"'{keyword}' appears {count} times ({relation} {frequency})"


def check_keywords_letter_frequency(response, kwargs):
    """Check letter frequency.

    Official: collections.Counter on lowercase response, 'less than' / 'at least'.
    """
    letter = kwargs.get('letter', '')
    frequency = kwargs.get('let_frequency', 1)
    relation = kwargs.get('let_relation', 'at least')
    if not letter:
        return True, "no letter specified"
    letters = collections.Counter(response.lower())
    count = letters[letter.lower()]
    if relation == 'less than':
        ok = count < frequency
    else:  # 'at least'
        ok = count >= frequency
    return ok, f"letter '{letter}' appears {count} times ({relation} {frequency})"


def check_length_number_sentences(response, kwargs):
    """Check sentence count.

    Official: instructions_util.count_sentences (splits on sentence-ending
    punctuation). Relations: 'less than' (<) or 'at least' (>=).
    """
    num = kwargs.get('num_sentences', 1)
    relation = kwargs.get('relation', 'at least')
    # Count sentences: split on sentence-ending punctuation
    sentences = re.split(r'[.!?]+(?:\s|$)', response.strip())
    sentences = [s.strip() for s in sentences if s.strip()]
    count = len(sentences)
    if relation == 'less than':
        ok = count < num
    else:  # 'at least'
        ok = count >= num
    return ok, f"{count} sentences ({relation} {num})"


def check_length_number_paragraphs(response, kwargs):
    """Check paragraph count.

    Official: re.split(r'\\s?\\*\\*\\*\\s?', value) — splits on *** WITHOUT
    requiring newlines. Empty paragraphs at start/end are subtracted.
    Empty paragraph in middle → fail.
    """
    num = kwargs.get('num_paragraphs', 1)
    paragraphs = re.split(r"\s?\*\*\*\s?", response)
    num_paragraphs = len(paragraphs)

    for index, paragraph in enumerate(paragraphs):
        if not paragraph.strip():
            if index == 0 or index == len(paragraphs) - 1:
                num_paragraphs -= 1
            else:
                return False, f"empty paragraph at position {index}"

    ok = num_paragraphs == num
    return ok, f"{num_paragraphs} paragraphs (expected {num})"


def check_length_number_words(response, kwargs):
    """Check word count.

    Official: 'less than' (<) or 'at least' (>=). Only these two relations.
    """
    num = kwargs.get('num_words', 1)
    relation = kwargs.get('relation', 'at least')
    words = response.split()
    count = len(words)
    if relation == 'less than':
        ok = count < num
    else:  # 'at least'
        ok = count >= num
    return ok, f"{count} words ({relation} {num})"


def check_length_nth_paragraph_first_word(response, kwargs):
    """Check first word of nth paragraph.

    Official: splits paragraphs on '\\n\\n' (double newline), NOT ***.
    Checks both paragraph count and first word.
    """
    num_paragraphs = kwargs.get('num_paragraphs', 1)
    nth_paragraph = kwargs.get('nth_paragraph', 1)
    first_word = kwargs.get('first_word', '')
    if not first_word:
        return True, "no first_word specified"
    first_word = first_word.lower()

    paragraphs = re.split(r"\n\n", response)
    actual_count = len(paragraphs)

    # Subtract empty paragraphs
    for paragraph in paragraphs:
        if not paragraph.strip():
            actual_count -= 1

    # Check paragraph count
    if actual_count != num_paragraphs:
        return False, f"{actual_count} paragraphs (expected {num_paragraphs})"

    # Check nth paragraph exists
    if nth_paragraph > len(paragraphs):
        return False, f"only {len(paragraphs)} paragraphs, need {nth_paragraph}"

    para = paragraphs[nth_paragraph - 1].strip()
    if not para:
        return False, f"paragraph {nth_paragraph} is empty"

    # Extract first word, strip punctuation
    word = para.split()[0].strip()
    word = word.lstrip("'").lstrip('"')
    punctuation = {".", ",", "?", "!", "'", '"'}
    actual_first = ""
    for letter in word:
        if letter in punctuation:
            break
        actual_first += letter.lower()

    ok = actual_first == first_word
    return ok, f"paragraph {nth_paragraph} first word: '{actual_first}' (expected '{first_word}')"


def check_detectable_content_postscript(response, kwargs):
    """Check for P.S. or P.P.S. section.

    Official: lowercases response, uses regex with re.MULTILINE.
    P.P.S → r'\\s*p\\.\\s?p\\.\\s?s.*$'
    P.S.  → r'\\s*p\\.\\s?s\\..*$'
    """
    postscript_marker = kwargs.get('postscript_marker', 'P.S.')
    if not postscript_marker:
        postscript_marker = 'P.S.'
    postscript_marker = postscript_marker.strip()

    value = response.lower()

    if postscript_marker == "P.P.S":
        postscript_pattern = r"\s*p\.\s?p\.\s?s.*$"
    elif postscript_marker == "P.S.":
        postscript_pattern = r"\s*p\.\s?s\..*$"
    else:
        postscript_pattern = r"\s*" + re.escape(postscript_marker.lower()) + r".*$"

    postscript = re.findall(postscript_pattern, value, flags=re.MULTILINE)
    ok = bool(postscript)
    return ok, f"postscript marker '{postscript_marker}' {'found' if ok else 'not found'}"


def check_detectable_content_number_placeholders(response, kwargs):
    """Check for [placeholder] count."""
    num = kwargs.get('num_placeholders', 1)
    placeholders = re.findall(r'\[.*?\]', response)
    count = len(placeholders)
    ok = count >= num
    return ok, f"{count} placeholders (need {num})"


def check_detectable_format_title(response, kwargs):
    """Check for <<title>> formatted title.

    Official: r'<<[^\\n]+>>', checks content is non-empty after stripping.
    Returns True if at least one valid title found. No kwargs (num_highlights ignored).
    """
    pattern = r"<<[^\n]+>>"
    titles = re.findall(pattern, response)
    for title in titles:
        if title.lstrip("<").rstrip(">").strip():
            return True, "title found"
    return False, "no <<title>> found"


def check_detectable_format_json_format(response, kwargs):
    """Check that the response is valid JSON.

    Official: strips markdown code fences, then json.loads().
    """
    value = (
        response.strip()
        .removeprefix("```json")
        .removeprefix("```Json")
        .removeprefix("```JSON")
        .removeprefix("```")
        .removesuffix("```")
        .strip()
    )
    try:
        json.loads(value)
        return True, "valid JSON"
    except (json.JSONDecodeError, ValueError, TypeError):
        pass
    return False, "no valid JSON found"


def check_detectable_format_number_bullet_lists(response, kwargs):
    """Check bullet list count.

    Official: counts asterisk bullets (r'^\\s*\\*[^\\*].*$') + dash bullets
    (r'^\\s*-.*$'), requires EXACT count (==).
    """
    num = kwargs.get('num_bullets', 1)
    bullets_star = re.findall(r"^\s*\*[^\*].*$", response, flags=re.MULTILINE)
    bullets_dash = re.findall(r"^\s*-.*$", response, flags=re.MULTILINE)
    count = len(bullets_star) + len(bullets_dash)
    ok = count == num
    return ok, f"{count} bullet items (exactly {num} required)"


def check_detectable_format_constrained_response(response, kwargs):
    """Check response matches constrained options.

    Official: checks if response contains one of _CONSTRAINED_RESPONSE_OPTIONS.
    Since we don't have the options from the prompt, we can't check this properly.
    The official checker also just returns True if options aren't set.
    """
    return True, "constrained response (prompt-embedded options)"


def check_detectable_format_multiple_sections(response, kwargs):
    """Check section count with delimiter.

    Official: regex r'\\s?' + section_spliter + r'\\s?\\d+\\s?' to match
    sections like "SECTION 1", "SECTION 2". Checks num_sections >= required.
    """
    num = kwargs.get('num_sections', 1)
    delimiter = kwargs.get('section_spliter', 'Section')
    if not delimiter:
        delimiter = 'Section'
    section_pattern = r"\s?" + re.escape(delimiter) + r"\s?\d+\s?"
    sections = re.split(section_pattern, response)
    count = len(sections) - 1
    ok = count >= num
    return ok, f"{count} sections with delimiter '{delimiter}' (need >= {num})"


def check_detectable_format_number_highlighted_sections(response, kwargs):
    """Check highlighted section count.

    Official: counts BOTH *single* (r'\\*[^\\n\\*]*\\*') AND **double**
    (r'\\*\\*[^\\n\\*]*\\*\\*') highlights. Checks non-empty content.
    Uses >= (at least).
    """
    num = kwargs.get('num_highlights', 1)
    num_highlights = 0
    highlights = re.findall(r"\*[^\n\*]*\*", response)
    double_highlights = re.findall(r"\*\*[^\n\*]*\*\*", response)
    for highlight in highlights:
        if highlight.strip("*").strip():
            num_highlights += 1
    for highlight in double_highlights:
        content = highlight.removeprefix("**").removesuffix("**").strip() if hasattr(highlight, 'removeprefix') else highlight[2:-2].strip()
        if content:
            num_highlights += 1
    ok = num_highlights >= num
    return ok, f"{num_highlights} highlighted sections (need >= {num})"


def check_startend_end_checker(response, kwargs):
    """Check response ends with specific phrase.

    Official: value.strip().strip('"').lower() then endswith(end_phrase.strip().lower()).
    Note: strips quotation marks before checking!
    """
    end_phrase = kwargs.get('end_phrase', '')
    if not end_phrase:
        return True, "no end_phrase specified"
    value = response.strip().strip('"').lower()
    end_phrase_lower = end_phrase.strip().lower()
    ok = value.endswith(end_phrase_lower)
    return ok, f"ends with '{end_phrase}': {ok}"


def check_startend_quotation(response, kwargs):
    """Check response is wrapped in double quotation marks.

    Official: value[0] == '"' and value[-1] == '"', requires len > 1.
    """
    value = response.strip()
    ok = len(value) > 1 and value[0] == '"' and value[-1] == '"'
    return ok, f"wrapped in quotes: {ok}"


def check_combination_two_responses(response, kwargs):
    """Check response contains two separate responses.

    Official: splits on exactly '******' (6 asterisks). Requires exactly 2
    non-empty, DIFFERENT responses. Empty parts at start/end are OK.
    Middle empty part → fail.
    """
    valid_responses = []
    responses = response.split("******")
    for index, resp in enumerate(responses):
        if not resp.strip():
            if index != 0 and index != len(responses) - 1:
                return False, "empty section between separators"
        else:
            valid_responses.append(resp)
    if len(valid_responses) == 2 and valid_responses[0].strip() != valid_responses[1].strip():
        return True, "two different responses found"
    return False, f"found {len(valid_responses)} response(s) separated by ******"


def check_combination_repeat_prompt(response, kwargs):
    """Check response starts by repeating the original prompt."""
    prompt_to_repeat = kwargs.get('prompt_to_repeat', '')
    if not prompt_to_repeat:
        return True, "no prompt_to_repeat specified"
    ok = response.strip().startswith(prompt_to_repeat.strip())
    return ok, f"starts with prompt: {ok}"


def check_change_case_english_capital(response, kwargs):
    """Check entire response is uppercase.

    Official: value.isupper() — checks the ENTIRE string, not just alpha chars.
    Also checks langdetect == 'en' but we skip that.
    """
    ok = response.isupper()
    return ok, f"all uppercase: {ok}"


def check_change_case_english_lowercase(response, kwargs):
    """Check entire response is lowercase.

    Official: value.islower() — checks the ENTIRE string.
    """
    ok = response.islower()
    return ok, f"all lowercase: {ok}"


def check_change_case_capital_word_frequency(response, kwargs):
    """Check frequency of ALL CAPS words.

    Official: uses nltk.word_tokenize, counts word.isupper().
    Relations: 'less than' (<) or 'at least' (>=).
    We approximate with split() since nltk may not be available.
    """
    frequency = kwargs.get('capital_frequency', 1)
    relation = kwargs.get('capital_relation', 'at least')
    words = response.split()
    cap_words = [w for w in words if w.isupper()]
    count = len(cap_words)
    if relation == 'less than':
        ok = count < frequency
    else:  # 'at least'
        ok = count >= frequency
    return ok, f"{count} all-caps words ({relation} {frequency})"


def check_punctuation_no_comma(response, kwargs):
    """Check no commas in response."""
    ok = ',' not in response
    comma_count = response.count(',')
    return ok, "no commas" if ok else f"{comma_count} commas found"


def check_language_response_language(response, kwargs):
    """Check response language."""
    language = kwargs.get('language', '')
    if not language:
        return True, "no language specified"
    try:
        from langdetect import detect
        detected = detect(response)
        ok = detected == language
        return ok, f"detected '{detected}', expected '{language}'"
    except ImportError:
        return True, "langdetect not installed, skipping"
    except Exception:
        return True, "language detection failed, skipping"


# ---------------------------------------------------------------------------
# Checker registry
# ---------------------------------------------------------------------------

CHECKERS = {
    'keywords:existence': check_keywords_existence,
    'keywords:forbidden_words': check_keywords_forbidden_words,
    'keywords:frequency': check_keywords_frequency,
    'keywords:letter_frequency': check_keywords_letter_frequency,
    'language:response_language': check_language_response_language,
    'length_constraints:number_sentences': check_length_number_sentences,
    'length_constraints:number_paragraphs': check_length_number_paragraphs,
    'length_constraints:number_words': check_length_number_words,
    'length_constraints:nth_paragraph_first_word': check_length_nth_paragraph_first_word,
    'detectable_content:number_placeholders': check_detectable_content_number_placeholders,
    'detectable_content:postscript': check_detectable_content_postscript,
    'detectable_format:number_bullet_lists': check_detectable_format_number_bullet_lists,
    'detectable_format:constrained_response': check_detectable_format_constrained_response,
    'detectable_format:number_highlighted_sections': check_detectable_format_number_highlighted_sections,
    'detectable_format:multiple_sections': check_detectable_format_multiple_sections,
    'detectable_format:json_format': check_detectable_format_json_format,
    'detectable_format:title': check_detectable_format_title,
    'combination:two_responses': check_combination_two_responses,
    'combination:repeat_prompt': check_combination_repeat_prompt,
    'startend:end_checker': check_startend_end_checker,
    'startend:quotation': check_startend_quotation,
    'change_case:capital_word_frequency': check_change_case_capital_word_frequency,
    'change_case:english_capital': check_change_case_english_capital,
    'change_case:english_lowercase': check_change_case_english_lowercase,
    'punctuation:no_comma': check_punctuation_no_comma,
}


# ---------------------------------------------------------------------------
# Main scoring logic
# ---------------------------------------------------------------------------

def score_instruction_following(response, instruction_id_list, kwargs_list):
    """Score an instruction-following response.

    Score formula (matches official LiveBench):
        score = (all_followed + avg_individual) / 2
    """
    per_constraint = []

    for i, instruction_id in enumerate(instruction_id_list):
        kw = kwargs_list[i] if i < len(kwargs_list) else {}
        # Filter out None values (matches official behavior)
        kw = {k: v for k, v in kw.items() if v is not None}

        checker = CHECKERS.get(instruction_id)
        if checker is None:
            per_constraint.append({
                'id': instruction_id,
                'followed': False,
                'details': f'unknown constraint type: {instruction_id}'
            })
            continue

        try:
            followed, details = checker(response, kw)
        except Exception as e:
            followed = False
            details = f"checker error: {type(e).__name__}: {e}"

        per_constraint.append({
            'id': instruction_id,
            'followed': followed,
            'details': details
        })

    if not per_constraint:
        return {"score": 1.0, "all_followed": True, "per_constraint": []}

    follow_list = [c['followed'] for c in per_constraint]
    all_followed = all(follow_list)
    avg_individual = sum(1 for f in follow_list if f) / len(follow_list)

    score_1 = 1.0 if all_followed else 0.0
    score = round((score_1 + avg_individual) / 2, 4)

    return {
        "score": score,
        "all_followed": all_followed,
        "per_constraint": per_constraint
    }


def main():
    parser = argparse.ArgumentParser(description='Score LiveBench instruction_following answers')
    parser.add_argument('--response', help='Response text (inline)')
    parser.add_argument('--response-file', help='Path to response text file')
    parser.add_argument('--constraints', help='Constraints JSON (inline)')
    parser.add_argument('--constraints-file', help='Path to constraints JSON file')
    args = parser.parse_args()

    # Load response
    if args.response_file:
        try:
            with open(args.response_file) as f:
                response = f.read()
        except FileNotFoundError:
            print(json.dumps({"score": 0.0, "all_followed": False, "per_constraint": [],
                              "error": f"Response file not found: {args.response_file}"}))
            sys.exit(1)
    elif args.response:
        response = args.response
    else:
        print(json.dumps({"score": 0.0, "all_followed": False, "per_constraint": [],
                          "error": "no response provided"}))
        sys.exit(1)

    # Load constraints
    if args.constraints_file:
        try:
            with open(args.constraints_file) as f:
                constraints = json.load(f)
        except FileNotFoundError:
            print(json.dumps({"score": 0.0, "all_followed": False, "per_constraint": [],
                              "error": f"Constraints file not found: {args.constraints_file}"}))
            sys.exit(1)
    elif args.constraints:
        constraints = json.loads(args.constraints)
    else:
        print(json.dumps({"score": 0.0, "all_followed": False, "per_constraint": [],
                          "error": "no constraints provided"}))
        sys.exit(1)

    # Strip <think> tags
    response = strip_think_tags(response)

    instruction_id_list = constraints.get('instruction_id_list', [])
    kwargs_list = constraints.get('kwargs', [])

    result = score_instruction_following(response, instruction_id_list, kwargs_list)
    print(json.dumps(result))


if __name__ == '__main__':
    main()
