#!/usr/bin/env python3
"""Scores what Dossier read from the household documents against the answer key.

    python3 Tools/household/score_reading.py RESULTS_DIR [--key SampleDocuments/Household/answer-key.json] [--md report.md]

RESULTS_DIR holds one JSON per file, written by DossierTests/ReadingEvaluation. Reports, per file and overall:
- kind: whether the document type was recognised;
- fields: the standard facts, as the model read them and as the app keeps them after the verifier
  (correct / wrong / missing), and whether wrong values were caught (sent to Review);
- contents and details: how much of everything else on the page was captured (recall), with "important"
  items (the ones people ask about) reported separately;
- travel rows for the I-94.
"""
import argparse
import json
import os
import re
import sys
from collections import defaultdict
from datetime import date

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MONTHS = {m: i + 1 for i, m in enumerate(["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"])}
ABBREVIATIONS = {"STREET": "ST", "AVENUE": "AVE", "APARTMENT": "APT", "NORTHWEST": "NW", "SUITE": "STE", "UNIT": "APT", "#": "APT"}


def iso_dates(text):
    """Every date in the text, as YYYY-MM-DD, in any of the usual spellings."""
    found = set()
    t = text.upper()
    for y, m, d in re.findall(r"\b(\d{4})-(\d{1,2})-(\d{1,2})\b", t):
        found.add((int(y), int(m), int(d)))
    for m, d, y in re.findall(r"\b(\d{1,2})/(\d{1,2})/(\d{4})\b", t):
        found.add((int(y), int(m), int(d)))
    for d, mon, y in re.findall(r"\b(\d{1,2}) ([A-Z]{3})[A-Z]* (\d{4})\b", t):
        if mon in MONTHS:
            found.add((int(y), MONTHS[mon], int(d)))
    for mon, d, y in re.findall(r"\b([A-Z]{3})[A-Z]* (\d{1,2}),? (\d{4})\b", t):
        if mon in MONTHS:
            found.add((int(y), MONTHS[mon], int(d)))
    out = set()
    for y, m, d in found:
        try:
            out.add(date(y, m, d).isoformat())
        except ValueError:
            pass
    return out


def compact(text):
    return re.sub(r"[^A-Z0-9]", "", text.upper())


def words(text):
    t = text.upper().replace(",", " ").replace(".", " ")
    return [ABBREVIATIONS.get(w, w) for w in re.split(r"[\s/()·\-]+", t) if w]


def norm_field(key, value):
    v = value or ""
    if key in {"dateOfBirth", "issueDate", "expiryDate", "residentSince", "leaseStartDate", "leaseEndDate", "noticeDate",
               "admitUntil", "validFrom", "validUntil"}:
        dates = iso_dates(v)
        return min(dates) if dates else compact(v)
    if key == "alienNumber":
        return compact(v).lstrip("A").lstrip("0")
    if key == "address":
        return " ".join(words(v))
    if key == "sex":
        return compact(v)[:1]
    return compact(v)


def field_matches(key, expected, got):
    e, g = norm_field(key, expected), norm_field(key, got)
    if e == g:
        return "exact"
    if key in {"surname", "givenNames"}:
        a, b = words(expected), words(got)
        short, longer = (a, b) if len(a) <= len(b) else (b, a)
        if short and all(x == y or (len(x) == 1 and y.startswith(x)) or (len(y) == 1 and x.startswith(y)) for x, y in zip(short, longer)):
            return "compatible"
    if key in {"placeOfBirth", "nationality", "issuingAuthority"} and (e in g or g in e) and min(len(e), len(g)) >= 4:
        return "compatible"
    return None


def entry_tokens(value):
    """What must appear for an expected entry to count as captured: its dates, its numbers/codes, and its words."""
    parts = [p.strip() for p in value.split(" · ") if p.strip()]
    tokens = []
    for p in parts:
        ds = iso_dates(p)
        if ds:
            tokens.append(("date", min(ds)))
        else:
            tokens.append(("text", compact(re.sub(r"^(LOT|Lot|lot)\s+", "", p))))
    return tokens


def entry_captured(expected, candidates):
    """True when one candidate (label + value) contains every token of the expected value; dates in any spelling."""
    tokens = entry_tokens(expected["value"])
    label_words = {w for w in words(expected["label"]) if len(w) > 2 and w not in {"DOSE", "THE", "AND", "BOX"}}
    best = None
    for cand in candidates:
        text = f"{cand.get('section', '')} {cand.get('label', '')} {cand.get('value', '')}"
        dates, flat = iso_dates(text), compact(text)
        # Every date must be there; of the other parts (lot, clinic, units), most of them.
        date_ok = all(t[1] in dates for t in tokens if t[0] == "date")
        texts = [t for t in tokens if t[0] == "text"]
        found = sum(t[1] in flat for t in texts)
        has_date = any(t[0] == "date" for t in tokens)
        cand_words = set(words(text))
        # A dated row with the right label and date is captured even without its lot or clinic: that answers
        # "when was my flu shot". The lot and clinic are counted separately as row detail.
        label_match = bool(label_words & cand_words)
        ok = date_ok and (found == len(texts) or (has_date and found * 2 >= len(texts)) or (has_date and label_match)
                          or (not has_date and texts and found >= 1 and len(texts) > 1 and found * 2 > len(texts)))
        if not ok:
            continue
        # A bare value such as "$2,950.00" or "Negative" could be any row: also want a word of the label.
        label_ok = not label_words or bool(label_words & cand_words) or len("".join(t[1] for t in tokens)) >= 8
        if label_ok:
            return True
        best = best or False
    return False


def load_key(path):
    with open(path) as f:
        key = json.load(f)
    by_file = {}
    for doc in key["documents"]:
        for fl in doc["files"]:
            by_file[os.path.splitext(fl["path"])[0]] = (doc, fl["variant"])
    return key, by_file


def score_file(doc, out):
    s = {"kind_ok": out.get("kind") == doc["kind"], "error": out.get("error")}
    model = {f["key"]: f for f in out.get("fields", [])}
    kept = {v["key"]: v for v in out.get("verified", [])}
    rows = []
    for key, expected in doc["fields"].items():
        got = model.get(key)
        got_value = got["value"] if got else None
        match = field_matches(key, expected, got_value) if got else None
        k = kept.get(key)
        kept_match = field_matches(key, expected, k["value"]) if k else None
        rows.append({
            "key": key, "expected": expected, "read": got_value, "match": match,
            "confidence": got and got.get("confidence"), "kept": k and k["value"], "kept_match": kept_match,
            "status": k and k["status"], "check": k and k["check"],
        })
    s["fields"] = rows
    expected_keys = set(doc["fields"])
    s["extra_fields"] = [f for f in out.get("fields", []) if f["key"] not in expected_keys]

    candidates = out.get("contents", []) + [dict(d, section=d.get("person", "")) for d in out.get("details", [])] \
        + [{"label": f["key"], "value": f["value"]} for f in out.get("fields", [])]
    s["contents"] = [{"label": e["label"], "value": e["value"], "important": e["important"],
                      "captured": entry_captured(e, candidates)} for e in doc["contents"]]
    s["details"] = [{"label": d["label"], "value": d["value"], "person": d["person"], "important": d["important"],
                     "captured": entry_captured({"label": d["label"], "value": d["value"]}, candidates)} for d in doc["details"]]
    exp_travel = {(t["date"], t["kind"], t["port"]) for t in doc["travel"]}
    got_travel = {(t["date"], t["kind"], t["port"].upper()) for t in out.get("travel", [])}
    s["travel"] = {"expected": len(exp_travel), "found": len(exp_travel & got_travel), "extra": len(got_travel - exp_travel)}
    s["counts"] = {"contents_read": len(out.get("contents", [])), "details_read": len(out.get("details", []))}
    return s


def pct(a, b):
    return f"{100 * a / b:.0f}%" if b else "–"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("results")
    ap.add_argument("--key", default=os.path.join(ROOT, "SampleDocuments/Household/answer-key.json"))
    ap.add_argument("--md")
    ap.add_argument("--json")
    args = ap.parse_args()
    key, by_file = load_key(args.key)

    per_file = []
    for name in sorted(os.listdir(args.results)):
        if not name.endswith(".json"):
            continue
        with open(os.path.join(args.results, name)) as f:
            out = json.load(f)
        stem = os.path.splitext(out["file"])[0]
        if stem not in by_file:
            continue
        doc, variant = by_file[stem]
        s = score_file(doc, out)
        s.update(file=out["file"], doc=doc["id"], variant=variant, kind=doc["kind"], engine=out.get("engine"),
                 seconds=out.get("seconds"), mrz_found=out.get("mrzFound"), mrz_valid=out.get("mrzValid"),
                 mrz_failed=out.get("mrzFailedChecks"), barcode_found=out.get("barcodeFound"), barcode_parsed=out.get("barcodeParsed"),
                 read_kind=out.get("kind"))
        per_file.append(s)

    def totals(items):
        t = defaultdict(int)
        for s in items:
            t["files"] += 1
            t["kind_ok"] += s["kind_ok"]
            t["errors"] += bool(s["error"])
            for r in s["fields"]:
                t["fields"] += 1
                t["read_ok"] += r["match"] is not None
                t["read_exact"] += r["match"] == "exact"
                t["read_missing"] += r["read"] is None
                t["read_wrong"] += r["read"] is not None and r["match"] is None
                t["kept_ok"] += r["kept_match"] is not None
                t["kept_wrong"] += r["kept"] is not None and r["kept_match"] is None
                t["kept_wrong_flagged"] += r["kept"] is not None and r["kept_match"] is None and r["status"] == "needsReview"
                t["kept_ok_flagged"] += r["kept_match"] is not None and r["status"] == "needsReview"
                t["kept_ok_checked"] += r["kept_match"] is not None and r["check"] in {"mrz", "barcode"}
            for c in s["contents"] + s["details"]:
                t["items"] += 1
                t["items_captured"] += c["captured"]
                if c["important"]:
                    t["important"] += 1
                    t["important_captured"] += c["captured"]
            t["travel"] += s["travel"]["expected"]
            t["travel_found"] += s["travel"]["found"]
        return t

    groups = {"all": per_file}
    for s in per_file:
        groups.setdefault(f"variant: {s['variant']}", []).append(s)
        groups.setdefault(f"kind: {s['kind']}", []).append(s)

    lines = ["# Reading accuracy", "", f"Results: `{args.results}` · {len(per_file)} files", "",
             "| Group | Files | Kind right | Fields read right | Wrong (read) | Missing | Kept right | Kept wrong | Wrong caught by Review | Everything else captured | Important captured | Travel rows |",
             "|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for name, items in groups.items():
        t = totals(items)
        lines.append(f"| {name} | {t['files']} | {pct(t['kind_ok'], t['files'])} | {pct(t['read_ok'], t['fields'])} | {t['read_wrong']} | "
                     f"{t['read_missing']} | {pct(t['kept_ok'], t['fields'])} | {t['kept_wrong']} | {t['kept_wrong_flagged']}/{t['kept_wrong']} | "
                     f"{pct(t['items_captured'], t['items'])} | {pct(t['important_captured'], t['important'])} | "
                     f"{t['travel_found']}/{t['travel']} |")
    lines += ["", "## Problems by file", ""]
    for s in per_file:
        problems = []
        if s["error"]:
            problems.append(f"error: {s['error']}")
        if not s["kind_ok"]:
            problems.append(f"kind read as {s['read_kind']}")
        for r in s["fields"]:
            if r["match"] is None:
                problems.append(f"{r['key']}: expected `{r['expected']}`, read `{r['read']}`")
            elif r["kept_match"] is None:
                problems.append(f"{r['key']}: read right but dropped/changed by the app (kept `{r['kept']}`)")
            elif r["status"] == "needsReview":
                problems.append(f"{r['key']}: right, but sent to Review ({r['check']})")
        missed = [c for c in s["contents"] + s["details"] if not c["captured"]]
        for c in missed:
            problems.append(f"{'★ ' if c['important'] else ''}not captured: {c['label']} = `{c['value']}`")
        if s["travel"]["expected"] and s["travel"]["found"] < s["travel"]["expected"]:
            problems.append(f"travel rows {s['travel']['found']}/{s['travel']['expected']}")
        if s["mrz_found"] and not s["mrz_valid"]:
            problems.append(f"MRZ found but failed checks: {s['mrz_failed']}")
        if s["kind"] in {"passport", "greenCard", "employmentAuthorization"} and not s["mrz_found"]:
            problems.append("MRZ not found by OCR")
        if s["kind"] == "driversLicense" and not s["barcode_parsed"]:
            problems.append("licence barcode " + ("found but not parsed" if s["barcode_found"] else "not found"))
        lines.append(f"**{s['file']}** ({s['engine']}, {s['seconds'] or 0:.0f}s)" + (": all good" if not problems else ""))
        lines += [f"- {p}" for p in problems]
        lines.append("")
    report = "\n".join(lines)
    print(report)
    if args.md:
        with open(args.md, "w") as f:
            f.write(report)
    if args.json:
        with open(args.json, "w") as f:
            json.dump({"files": per_file, "totals": {k: totals(v) for k, v in groups.items()}}, f, indent=1)


if __name__ == "__main__":
    sys.exit(main())
