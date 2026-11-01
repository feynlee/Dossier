#!/usr/bin/env python3
"""Scores the answers DossierTests/AnswerEvaluation wrote.

    python3 Tools/household/score_answers.py ANSWERS_DIR [--md report.md]

An answer is right when it contains one of the question's accepted answers (dates in any spelling, numbers
and words ignoring case and punctuation). For a sensitive number, Siri may only say the last four characters,
so those count. Also reports, as a baseline, which questions the four fixed Siri intents Dossier had before
could answer at all.
"""
import argparse
import glob
import json
import os
import re
import statistics
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from score_reading import compact, iso_dates  # noqa: E402

# The questions the old intents (document number, expiry, where I lived, days abroad) could take at all.
OLD_INTENTS = [
    r"what's (my|david's|my husband's) (passport|driver's licence|green card|ead) number",
    r"when does (my|david's) (passport|driver's licence|green card) expire",
    r"where did (i|we) live in \d{4}",
    r"how many days was i outside the us in \d{4}",
    r"what's my a-number", r"what's my husband's a-number",
]


def spoken_dates(text):
    """Dates spoken as "14 March 2029" or written as ISO."""
    return iso_dates(text)


NUMBER_WORDS = {"one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7", "eight": "8",
                "nine": "9", "ten": "10", "eleven": "11", "twelve": "12"}


def spoken_forms(text):
    """The answer with number words as digits and 24-hour times also as 12-hour ones ("16:12" → "4:12 PM")."""
    out = re.sub(r"\b(" + "|".join(NUMBER_WORDS) + r")\b", lambda m: NUMBER_WORDS[m.group(1).lower()], text, flags=re.I)

    def twelve(m):
        h, mnt = int(m.group(1)), m.group(2)
        return f"{m.group(0)} ({(h - 1) % 12 + 1}:{mnt} {'PM' if h >= 12 else 'AM'})"
    return re.sub(r"\b(\d{1,2}):(\d{2})\b(?!\s*[AaPp][Mm])", twelve, out)


def correct(row):
    answer = spoken_forms(row["answer"])
    if not row["found"] and "couldn" in answer.lower():
        return False
    flat = compact(answer)
    dates = spoken_dates(answer)
    for accept in row["accept"]:
        accept_dates = iso_dates(accept)
        if accept_dates and accept_dates <= dates:
            return True
        if not accept_dates and compact(accept) and compact(accept) in flat:
            return True
    # The app keeps identification numbers hidden and says only their last four characters ("a number ending
    # in 4321"), so that counts for any number, not only the ones the answer key calls sensitive.
    if row["sensitive"] or "ending in" in answer.lower():
        tail = compact(row["expected"])[-4:]
        if tail and tail in flat:
            return True
    return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("answers")
    ap.add_argument("--md")
    args = ap.parse_args()
    files = sorted(glob.glob(os.path.join(args.answers, "answers-*.json")))
    lines = ["# Answer accuracy", "", "| Knowledge from | Strategy | Right | Not found | Wrong | Median s | Slowest s |", "|---|---|---|---|---|---|---|"]
    details = []
    questions = None
    for path in files:
        with open(path) as f:
            rows = json.load(f)
        if not rows:
            continue
        questions = questions or rows
        right = [r for r in rows if correct(r)]
        missing = [r for r in rows if not correct(r) and (not r["found"] or "couldn" in r["answer"].lower())]
        wrong = [r for r in rows if not correct(r) and r not in missing]
        secs = [r["seconds"] for r in rows]
        lines.append(f"| {rows[0]['knowledge']} | {rows[0]['strategy']} | {len(right)}/{len(rows)} ({100 * len(right) / len(rows):.0f}%) | "
                     f"{len(missing)} | {len(wrong)} | {statistics.median(secs):.2f} | {max(secs):.1f} |")
        by_kind = {}
        for r in rows:
            k = r["kind"]
            by_kind.setdefault(k, [0, 0])
            by_kind[k][1] += 1
            by_kind[k][0] += correct(r)
        details.append(f"\n## {rows[0]['knowledge']} · {rows[0]['strategy']}\n")
        details.append("By kind: " + ", ".join(f"{k} {a}/{b}" for k, (a, b) in sorted(by_kind.items())))
        details.append("")
        for r in rows:
            if not correct(r):
                details.append(f"- ✗ **{r['question']}** expected `{r['expected']}` · got: {r['answer']} ({r['method']})")
    if questions:
        old = [r for r in questions if any(re.fullmatch(p, r["question"].lower().rstrip("?").replace("’", "'")) for p in OLD_INTENTS)]
        lines += ["", f"Before this change, Siri's four fixed questions could take at most {len(old)}/{len(questions)} of these "
                  f"({100 * len(old) / len(questions):.0f}%), and only by naming a document."]
    report = "\n".join(lines + details)
    print(report)
    if args.md:
        with open(args.md, "w") as f:
            f.write(report)


if __name__ == "__main__":
    main()
