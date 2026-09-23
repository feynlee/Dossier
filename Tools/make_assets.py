#!/usr/bin/env python3
"""Regenerates the app icon and the specimen sample documents (all data is made up)."""
import os
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def check_digit(value):
    weights, total = [7, 3, 1], 0
    for i, c in enumerate(value):
        v = int(c) if c.isdigit() else (ord(c) - 55 if c.isalpha() else 0)
        total += v * weights[i % 3]
    return str(total % 10)


def app_icon():
    size = 1024
    im = Image.new("RGB", (size, size), (75, 69, 198))
    d = ImageDraw.Draw(im)
    # An ID card, like the app's badged tiles.
    d.rounded_rectangle((170, 280, 854, 744), radius=70, fill=(255, 255, 255))
    d.ellipse((250, 380, 430, 560), fill=(233, 233, 248))
    d.rounded_rectangle((250, 590, 430, 650), radius=30, fill=(233, 233, 248))
    for i, w in enumerate((330, 260, 300)):
        d.rounded_rectangle((480, 400 + i * 90, 480 + w, 440 + i * 90), radius=20, fill=(233, 233, 248))
    # The verified badge.
    d.ellipse((650, 560, 900, 810), fill=(75, 69, 198))
    d.ellipse((676, 586, 874, 784), fill=(94, 92, 230))
    d.line((718, 690, 762, 734, 838, 640), fill=(255, 255, 255), width=34, joint="curve")
    path = os.path.join(ROOT, "Dossier/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
    im.save(path)


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


if __name__ == "__main__":
    app_icon()
    samples()
