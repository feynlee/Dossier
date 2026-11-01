#!/usr/bin/env python3
"""Builds SampleDocuments/Household: a made-up family's documents in clean, phone-photo, low-resolution and
scanned versions, plus answer-key.json (what each file says) and questions.json (what Siri should answer).

    python3 Tools/household/make_household.py

Needs reportlab, pdf417gen, Pillow, numpy and pdftoppm (poppler). Output is deterministic.
"""
import json
import os
import random
import shutil
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageEnhance

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import household  # noqa: E402
import render  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "SampleDocuments", "Household")
CARDS = {"passport", "greencard", "ead", "dl", "ssn", "insurance"}


def rasterize(pdf, dpi):
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(["pdftoppm", "-r", str(dpi), "-png", pdf, os.path.join(tmp, "p")], check=True)
        return [Image.open(os.path.join(tmp, name)).convert("RGB") for name in sorted(os.listdir(tmp))]


def noise(image, sigma, rng):
    a = np.asarray(image).astype(np.float32)
    a += np.random.default_rng(rng.randint(0, 1 << 30)).normal(0, sigma, a.shape)
    return Image.fromarray(np.clip(a, 0, 255).astype(np.uint8))


def perspective_coeffs(src, dst):
    """Coefficients for Image.transform(PERSPECTIVE) mapping output points `dst` back to input points `src`."""
    matrix = []
    for (x, y), (u, v) in zip(dst, src):
        matrix.append([x, y, 1, 0, 0, 0, -u * x, -u * y])
        matrix.append([0, 0, 0, x, y, 1, -v * x, -v * y])
    a = np.array(matrix, dtype=np.float64)
    b = np.array([p for pair in src for p in pair], dtype=np.float64)
    return np.linalg.solve(a, b).tolist()


def phone_photo(page, rng):
    """The page lying on a desk, shot at an angle in uneven light."""
    w, h = page.size
    margin = int(max(w, h) * 0.12)
    W, H = w + 2 * margin, h + 2 * margin
    desk = Image.new("RGB", (W, H), rng.choice([(122, 98, 74), (86, 92, 99), (168, 160, 148)]))
    desk = noise(desk, 9, rng).filter(ImageFilter.GaussianBlur(2))
    j = lambda s: rng.uniform(-s, s) * min(w, h)  # noqa: E731
    corners = [(margin + j(0.06), margin + j(0.05)), (margin + w + j(0.06), margin + j(0.05)),
               (margin + w + j(0.04), margin + h + j(0.06)), (margin + j(0.04), margin + h + j(0.06))]
    coeffs = perspective_coeffs([(0, 0), (w, 0), (w, h), (0, h)], corners)
    warped = page.transform((W, H), Image.PERSPECTIVE, coeffs, Image.BICUBIC, fillcolor=(0, 0, 0))
    mask = Image.new("L", (W, H), 0)
    ImageDraw.Draw(mask).polygon(corners, fill=255)
    desk.paste(warped, (0, 0), mask)
    # Shadow across one side, from the phone.
    shade = np.linspace(rng.uniform(0.55, 0.7), 1.0, W)[None, :, None]
    if rng.random() < 0.5:
        shade = shade[:, ::-1]
    a = np.asarray(desk).astype(np.float32) * shade
    a[..., 2] *= 0.95  # warm indoor light
    photo = Image.fromarray(np.clip(a, 0, 255).astype(np.uint8))
    photo = photo.filter(ImageFilter.GaussianBlur(rng.uniform(0.9, 1.5)))
    photo = noise(photo, 6, rng)
    return photo.resize((int(W * 0.7), int(H * 0.7)), Image.LANCZOS)


def low_resolution(page, rng):
    w, h = page.size
    small = page.resize((720, int(720 * h / w)), Image.BILINEAR).filter(ImageFilter.GaussianBlur(0.8))
    return ImageEnhance.Contrast(small).enhance(0.8)


def scanned(page, rng):
    """A tired office scanner: greyscale, crooked, speckled, a little faded."""
    g = page.convert("L")
    g = ImageEnhance.Contrast(g).enhance(1.25)
    g = g.rotate(rng.uniform(-2.2, 2.2), resample=Image.BICUBIC, expand=False, fillcolor=245)
    a = np.asarray(g).astype(np.float32)
    rs = np.random.default_rng(rng.randint(0, 1 << 30))
    a += rs.normal(0, 10, a.shape)
    speckle = rs.random(a.shape) < 0.0015
    a[speckle] = 30
    a = a * 0.92 + 14
    g = Image.fromarray(np.clip(a, 0, 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(0.6))
    return g


def main():
    if os.path.isdir(OUT):
        shutil.rmtree(OUT)
    os.makedirs(OUT)
    rng = random.Random(20261031)
    key = {"today": household.TODAY, "people": household.PEOPLE, "documents": [], "conflicts": household.CONFLICTS}
    with tempfile.TemporaryDirectory() as tmp:
        for doc in household.DOCUMENTS:
            pdf = os.path.join(tmp, doc["id"] + ".pdf")
            render.render(doc, household.PEOPLE, pdf)
            files = []
            is_card = doc["template"] in CARDS
            for variant in doc["variants"]:
                name = doc["file"] + ("" if variant == "clean" else f" ({variant})")
                if variant == "clean" and not is_card:
                    path = name + ".pdf"
                    shutil.copy(pdf, os.path.join(OUT, path))
                elif variant == "clean":
                    path = name + ".jpg"
                    rasterize(pdf, 150)[0].save(os.path.join(OUT, path), quality=90)
                elif variant == "photo":
                    pages = rasterize(pdf, 150)
                    path = name + ".jpg"
                    phone_photo(pages[0], rng).save(os.path.join(OUT, path), quality=72)
                elif variant == "lowres":
                    path = name + ".jpg"
                    low_resolution(rasterize(pdf, 150)[0], rng).save(os.path.join(OUT, path), quality=45)
                elif variant == "scan":
                    pages = [scanned(p, rng) for p in rasterize(pdf, 150)]
                    path = name + ".pdf"
                    pages[0].save(os.path.join(OUT, path), save_all=True, append_images=pages[1:], resolution=150)
                else:
                    raise ValueError(variant)
                files.append({"path": path, "variant": variant})
            key["documents"].append({
                "id": doc["id"], "holder": doc["holder"], "kind": doc["kind"], "files": files,
                "fields": doc["fields"], "contents": doc["contents"], "details": doc["details"],
                "travel": [{"date": a, "kind": b, "port": p} for a, b, p in doc["travel"]],
            })
    with open(os.path.join(OUT, "answer-key.json"), "w") as f:
        json.dump(key, f, indent=1, ensure_ascii=False)
    with open(os.path.join(OUT, "questions.json"), "w") as f:
        json.dump({"today": household.TODAY, "questions": household.QUESTIONS}, f, indent=1, ensure_ascii=False)
    count = sum(len(d["files"]) for d in key["documents"])
    print(f"{len(key['documents'])} documents, {count} files, {len(household.QUESTIONS)} questions -> {OUT}")


if __name__ == "__main__":
    main()
