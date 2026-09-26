#!/usr/bin/env python3
"""Regenerates the app icon (Icon Composer `Dossier/AppIcon.icon`, plus a flat copy in the asset catalog) and the specimen sample documents (all data is made up)."""
import os
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def check_digit(value):
    weights, total = [7, 3, 1], 0
    for i, c in enumerate(value):
        v = int(c) if c.isdigit() else (ord(c) - 55 if c.isalpha() else 0)
        total += v * weights[i % 3]
    return str(total % 10)


TINT = (75, 69, 198)  # Theme.dsTintFill (#4B45C6)


def d_keyhole(scale=2):
    """The glyph: a heavy geometric D with a keyhole cut through it, white on transparent, 1024 px.

    Same letter weight and size as BillSplit's B. Drawn at 2x and downsampled for smooth edges.
    """
    S = 1024 * scale

    def px(v):
        return int(round(v * scale))

    left, top, right, bottom = 232, 196, 792, 828   # the letter's box, centered
    rx = 300                                        # horizontal radius of the bowl
    mask = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(mask)
    d.rectangle((px(left), px(top), px(right - rx), px(bottom)), fill=255)
    d.pieslice((px(right - 2 * rx), px(top), px(right), px(bottom)), -90, 90, fill=255)
    # The keyhole, centered in the letter's visual mass.
    cx, cy, r = (left + right) / 2 - 20, (top + bottom) / 2 - 40, 78
    d.ellipse((px(cx - r), px(cy - r), px(cx + r), px(cy + r)), fill=0)
    d.polygon([(px(cx - 38), px(cy + 30)), (px(cx + 38), px(cy + 30)),
               (px(cx + 62), px(cy + 230)), (px(cx - 62), px(cy + 230))], fill=0)
    mask = mask.resize((1024, 1024), Image.LANCZOS)
    glyph = Image.new("RGBA", (1024, 1024), (255, 255, 255, 0))
    glyph.putalpha(mask)
    return glyph


def app_icon():
    """Writes the Icon Composer icon (Dossier/AppIcon.icon) and a flat copy for the asset catalog."""
    import json
    glyph = d_keyhole()

    bundle = os.path.join(ROOT, "Dossier/AppIcon.icon")
    os.makedirs(os.path.join(bundle, "Assets"), exist_ok=True)
    glyph.save(os.path.join(bundle, "Assets", "D-Keyhole.png"))
    r, g, b = (c / 255 for c in TINT)
    icon = {
        "fill": {"automatic-gradient": f"srgb:{r:.5f},{g:.5f},{b:.5f},1.00000"},
        "groups": [{
            "layers": [{"glass": True, "image-name": "D-Keyhole.png", "name": "D-Keyhole"}],
            "shadow": {"kind": "neutral", "opacity": 0.5},
            "translucency": {"enabled": True, "value": 0.4},
        }],
        "supported-platforms": {"circles": ["watchOS"], "squares": "shared"},
    }
    with open(os.path.join(bundle, "icon.json"), "w") as f:
        json.dump(icon, f, indent=2, separators=(",", " : "))
        f.write("\n")

    flat = Image.new("RGBA", (1024, 1024), TINT + (255,))
    flat.alpha_composite(glyph)
    flat.convert("RGB").save(os.path.join(ROOT, "Dossier/Assets.xcassets/AppIcon.appiconset/AppIcon.png"))


def samples():
    out = os.path.join(ROOT, "SampleDocuments")
    os.makedirs(out, exist_ok=True)
    doc, dob, exp = "PX7204821", "900812", "290314"
    l2 = doc + check_digit(doc) + "UTO" + dob + check_digit(dob) + "F" + exp + check_digit(exp) + "<" * 14 + "0"
    l2 += check_digit(l2[0:10] + l2[13:20] + l2[21:43])
    l1 = ("P<UTOERIKSSON<<ANNA<MARIA" + "<" * 44)[:44]
    mono = ImageFont.truetype("/System/Library/Fonts/Courier.ttc", 44)
    sans = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 30)
    label = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 20)
    big = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 40)

    im = Image.new("RGB", (1500, 1000), (236, 240, 232))
    d = ImageDraw.Draw(im)
    d.text((60, 40), "SPECIMEN · UTOPIA · PASSPORT / PASSEPORT", font=big, fill=(40, 60, 50))
    d.rectangle((60, 130, 400, 560), outline=(120, 130, 120), width=3)
    d.text((150, 330), "PHOTO", font=sans, fill=(120, 130, 120))
    y = 130
    for a, b in [("Passport No. / No du passeport", doc), ("Surname / Nom", "ERIKSSON"), ("Given names / Prénoms", "ANNA MARIA"),
                 ("Nationality / Nationalité", "UTOPIAN"), ("Date of birth / Date de naissance", "12 AUG 1990"), ("Sex / Sexe", "F"),
                 ("Date of issue / Date de délivrance", "15 MAR 2019"), ("Date of expiry / Date d'expiration", "14 MAR 2029"),
                 ("Authority / Autorité", "PASSPORT OFFICE UTOPIA")]:
        d.text((450, y), a, font=label, fill=(90, 100, 95))
        d.text((450, y + 22), b, font=sans, fill=(20, 20, 20))
        y += 70
    d.text((60, 860), l1, font=mono, fill=(10, 10, 10))
    d.text((60, 915), l2, font=mono, fill=(10, 10, 10))
    im.save(os.path.join(out, "Passport scan.jpg"), quality=92)

    def pdf(name, pages_lines):
        pages = []
        for lines in pages_lines:
            page = Image.new("RGB", (1275, 1650), "white")
            pd = ImageDraw.Draw(page)
            y = 120
            for text, font in lines:
                pd.text((110, y), text, font=font, fill="black")
                y += 60 if font == big else 48
            pages.append(page)
        pages[0].save(os.path.join(out, name), save_all=True, append_images=pages[1:], resolution=150)

    pdf("Lease 2020.pdf", [[
        ("RESIDENTIAL LEASE AGREEMENT", big), ("", sans),
        ('This lease is made between Alder Street Apartments LLC ("Landlord")', sans), ('and Anna Maria Eriksson ("Tenant").', sans), ("", sans),
        ("1. Premises", big), ("412 Alder St, Apt 3B, Seattle, WA 98101", sans), ("", sans),
        ("2. Term", big), ("The term begins on August 1, 2020 and ends on July 31, 2022.", sans), ("", sans),
        ("3. Rent", big), ("Monthly rent is $2,150.00, due on the first day of each month.", sans)],
        [("4. Signatures", big), ("", sans), ("Landlord: Alder Street Apartments LLC", sans), ("Tenant: Anna Maria Eriksson", sans),
         ("Signed on July 15, 2020", sans), ("", sans), ("SPECIMEN FOR TESTING · NOT A REAL LEASE", sans)]])

    pdf("Lease 2023.pdf", [[
        ("RESIDENTIAL LEASE AGREEMENT", big), ("", sans),
        ('This lease is made between Pine Avenue Homes ("Landlord")', sans), ('and Anna Maria Eriksson ("Tenant").', sans), ("", sans),
        ("1. Premises", big), ("88 Pine Ave, Portland, OR 97205", sans), ("", sans),
        ("2. Term", big), ("The term begins on January 1, 2023 and ends on December 31, 2027.", sans), ("", sans),
        ("SPECIMEN FOR TESTING · NOT A REAL LEASE", sans)]])

    rows = [("2025-03-22", "Arrival", "SEA"), ("2025-03-10", "Departure", "PDX"), ("2024-08-25", "Arrival", "SEA"),
            ("2024-08-09", "Departure", "SEA"), ("2023-04-16", "Arrival", "PDX"), ("2023-04-07", "Departure", "PDX"),
            ("2021-07-03", "Arrival", "SEA"), ("2021-06-12", "Departure", "SEA")]
    table = [("I-94 TRAVEL HISTORY", big), ("Name: ERIKSSON, ANNA MARIA · Passport: PX7204821", sans), ("", sans),
             ("#   Date          Type         Location", sans)]
    table += [(f"{i + 1}   {date}    {kind:<10}   {port}", sans) for i, (date, kind, port) in enumerate(rows)]
    table += [("", sans), ("SPECIMEN FOR TESTING · NOT A REAL RECORD", sans)]
    pdf("I-94 travel history.pdf", [table])


def sample_form():
    """A one-page AcroForm PDF with USCIS-style field names, written by hand (no PDF library needed)."""
    fields = [
        ("form1[0].Pt2Line1a_FamilyName[0]", "Family Name (Last Name)"),
        ("form1[0].Pt2Line1b_GivenName[0]", "Given Name (First Name)"),
        ("form1[0].Pt2Line1c_MiddleName[0]", "Middle Name"),
        ("form1[0].Pt2Line5_StreetNumberName[0]", "Street Number and Name"),
        ("form1[0].Pt2Line5_AptSteFlrNumber[0]", "Apt. Ste. Flr. Number"),
        ("form1[0].Pt2Line5_CityOrTown[0]", "City or Town"),
        ("form1[0].Pt2Line5_State[0]", "State"),
        ("form1[0].Pt2Line5_ZipCode[0]", "ZIP Code"),
        ("form1[0].Pt2Line7_AlienNumber[0]", "A-Number"),
        ("form1[0].Pt2Line19_DateOfBirth[0]", "Date of Birth (mm/dd/yyyy)"),
        ("form1[0].Pt2Line20a_PassportNumber[0]", "Passport Number"),
        ("form1[0].Pt2Line21_DateOfLastArrival[0]", "Date of Last Arrival (mm/dd/yyyy)"),
        ("form1[0].Pt2Line27_EligibilityCategory[0]", "Eligibility Category"),
        ("form1[0].Pt3Line7_Signature[0]", "Applicant's Signature"),
    ]
    objects = []  # index 0 -> object 1
    def add(body):
        objects.append(body)
        return len(objects)

    font = add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    field_ids = list(range(len(objects) + 4, len(objects) + 4 + len(fields)))
    catalog = add(f"<< /Type /Catalog /Pages 3 0 R /AcroForm << /Fields [{' '.join(f'{i} 0 R' for i in field_ids)}] "
                  f"/NeedAppearances true /DA (/Helv 10 Tf 0 g) /DR << /Font << /Helv {font} 0 R >> >> >> >>")
    pages = add("<< /Type /Pages /Kids [4 0 R] /Count 1 >>")
    lines = ["BT /F1 16 Tf 50 750 Td (SAMPLE APPLICATION FORM - SPECIMEN FOR TESTING) Tj ET"]
    y = 700
    rects = []
    for name, label in fields:
        lines.append(f"BT /F1 9 Tf 50 {y + 18} Td ({label.replace('(', '[').replace(')', ']')}) Tj ET")
        rects.append((50, y, 400, y + 16))
        y -= 46
    stream = "\n".join(lines)
    content_id = len(objects) + 1 + 1 + len(fields)  # after page and fields
    page = add(f"<< /Type /Page /Parent 3 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 {font} 0 R >> >> "
               f"/Annots [{' '.join(f'{i} 0 R' for i in field_ids)}] /Contents {content_id} 0 R >>")
    for (name, label), (x1, y1, x2, y2) in zip(fields, rects):
        add(f"<< /Type /Annot /Subtype /Widget /FT /Tx /T ({name}) /TU ({label}) /Rect [{x1} {y1} {x2} {y2}] "
            f"/P {page} 0 R /F 4 /DA (/Helv 10 Tf 0 g) /MK << /BC [0.6 0.6 0.6] >> >>")
    add(f"<< /Length {len(stream)} >>\nstream\n{stream}\nendstream")
    assert catalog == 2 and pages == 3 and page == 4

    out = b"%PDF-1.7\n"
    offsets = []
    for number, body in enumerate(objects, start=1):
        offsets.append(len(out))
        out += f"{number} 0 obj\n{body}\nendobj\n".encode("latin-1")
    xref = len(out)
    out += f"xref\n0 {len(objects) + 1}\n0000000000 65535 f \n".encode()
    for offset in offsets:
        out += f"{offset:010d} 00000 n \n".encode()
    out += f"trailer\n<< /Size {len(objects) + 1} /Root 2 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode()
    with open(os.path.join(ROOT, "SampleDocuments", "Sample application form.pdf"), "wb") as f:
        f.write(out)


if __name__ == "__main__":
    import sys
    app_icon()
    if "--icon-only" not in sys.argv:
        samples()
        sample_form()
