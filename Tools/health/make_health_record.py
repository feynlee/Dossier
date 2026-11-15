"""Makes a made-up patient health summary for testing how Dossier reads a health record and answers questions
about it ("What's my blood type?"). Everything on it is fictional and stamped SPECIMEN.

Writes SampleDocuments/Health/ with the clean PDF, a phone photo of it, and answer-key.json.
Run from the repository root: python3 Tools/health/make_health_record.py
"""

import json
import os
import random
import sys

from reportlab.lib.pagesizes import letter
from reportlab.pdfgen import canvas

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "Tools", "household"))

import render  # noqa: E402
from make_household import phone_photo, rasterize  # noqa: E402

OUT = os.path.join(ROOT, "SampleDocuments", "Health")
NAME = "Anna · Health summary"

PATIENT = [
    ("Patient name", "Anna Maria Eriksson"),
    ("Date of birth", "August 12, 1990"),
    ("Sex", "Female"),
    ("Medical record number", "MRN 4471-2290"),
    ("Primary care physician", "Dr. Tomas Lind, MD"),
]
VITALS = [
    ("Blood type", "O Rh positive (O+)"),
    ("Height", "5 ft 6 in (168 cm)"),
    ("Weight", "138 lb (62.6 kg)"),
    ("Blood pressure", "116/74 mmHg"),
]
ALLERGIES = [["Penicillin", "Hives", "Moderate"], ["Peanuts", "Throat swelling", "Severe"]]
CONDITIONS = [["Asthma, mild intermittent", "2009", "Active"], ["Iron-deficiency anemia", "2019", "Resolved"]]
MEDICATIONS = [["Albuterol inhaler 90 mcg", "2 puffs as needed"], ["Ferrous sulfate 325 mg", "Stopped 2020-03-01"]]
CONTACT = [("Emergency contact", "David Lee Chen (spouse)"), ("Contact phone", "(503) 555-0188")]


def draw(path):
    c = canvas.Canvas(path, pagesize=letter)
    y = render.letter_page(c, "PATIENT HEALTH SUMMARY", "Printed 14 September 2026 · SPECIMEN · made-up record",
                           org="HARBOR FAMILY MEDICINE · SPECIMEN")
    y = render.heading(c, y, "Patient")
    y = render.kv_rows(c, y, PATIENT, label_w=170)
    y = render.heading(c, y, "Vitals and blood type")
    y = render.kv_rows(c, y, VITALS, label_w=170)
    y = render.heading(c, y, "Allergies")
    y = render.table(c, y, ["Allergen", "Reaction", "Severity"], ALLERGIES, [180, 180, 120])
    y = render.heading(c, y, "Conditions")
    y = render.table(c, y, ["Condition", "Since", "Status"], CONDITIONS, [240, 100, 120])
    y = render.heading(c, y, "Medications")
    y = render.table(c, y, ["Medication", "Directions"], MEDICATIONS, [240, 240])
    y = render.heading(c, y, "Emergency contact")
    render.kv_rows(c, y, CONTACT, label_w=170)
    c.showPage()
    c.save()


def main():
    os.makedirs(OUT, exist_ok=True)
    pdf = os.path.join(OUT, NAME + ".pdf")
    draw(pdf)
    page = rasterize(pdf, 150)[0]
    phone_photo(page, random.Random(20261101)).save(os.path.join(OUT, NAME + " (photo).jpg"), quality=88)
    key = {
        "holder": "Anna",
        "kind": "other",
        "contents": [{"label": label, "value": value} for label, value in PATIENT + VITALS + CONTACT],
        "questions": [
            {"question": "What's my blood type?", "accept": ["O+", "O positive", "O Rh positive"]},
            {"question": "Can you find my blood type in Dossier?", "accept": ["O+", "O positive", "O Rh positive"]},
            {"question": "What's my blood group?", "accept": ["O+", "O positive", "O Rh positive"]},
            {"question": "What am I allergic to?", "accept": ["Penicillin", "Peanuts"]},
            {"question": "Who is my primary care doctor?", "accept": ["Lind"]},
            {"question": "Who's my emergency contact?", "accept": ["David"]},
        ],
    }
    with open(os.path.join(OUT, "answer-key.json"), "w") as f:
        json.dump(key, f, indent=2, ensure_ascii=False)
    print("Wrote", OUT)


if __name__ == "__main__":
    main()
