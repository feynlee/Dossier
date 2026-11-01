"""Draws each household document as a born-digital PDF with reportlab. `make_household.py` turns these into the
clean, photo and scan files. Every page carries a SPECIMEN watermark and footer."""
from datetime import date
from io import BytesIO

import pdf417gen
from reportlab.lib.colors import Color, HexColor, black
from reportlab.lib.pagesizes import letter
from reportlab.lib.utils import ImageReader
from reportlab.pdfgen import canvas

MONTHS = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
GREY = HexColor("#5B6360")
INK = HexColor("#151515")


def d(iso):
    return date.fromisoformat(iso)


def icao(iso):
    """12 AUG 1990"""
    x = d(iso)
    return f"{x.day:02d} {MONTHS[x.month - 1]} {x.year}"


def us(iso):
    """08/12/1990"""
    x = d(iso)
    return f"{x.month:02d}/{x.day:02d}/{x.year}"


def long(iso):
    """August 12, 1990"""
    return d(iso).strftime("%B %-d, %Y")


def check_digit(value):
    weights, total = [7, 3, 1], 0
    for i, c in enumerate(value):
        v = int(c) if c.isdigit() else (ord(c) - 55 if c.isalpha() else 0)
        total += v * weights[i % 3]
    return str(total % 10)


def yymmdd(iso):
    return iso[2:4] + iso[5:7] + iso[8:10]


# ------------------------------------------------------------------------------------------------ Page basics

def watermark(c, w, h, size=None):
    c.saveState()
    c.setFillColor(Color(0.85, 0.2, 0.2, alpha=0.10))
    c.setFont("Helvetica-Bold", size or min(w, h) / 5)
    c.translate(w / 2, h / 2)
    c.rotate(28)
    c.drawCentredString(0, -size / 3 if size else -min(w, h) / 15, "SPECIMEN")
    c.restoreState()


def footer(c, w, text="SPECIMEN FOR TESTING · NOT A REAL DOCUMENT · ALL DATA IS FICTIONAL"):
    c.setFont("Helvetica", 7)
    c.setFillColor(GREY)
    c.drawCentredString(w / 2, 18, text)
    c.setFillColor(INK)


def letter_page(c, title, subtitle=None, org=None):
    w, h = letter
    watermark(c, w, h, 110)
    footer(c, w)
    y = h - 60
    if org:
        c.setFont("Helvetica-Bold", 10)
        c.setFillColor(GREY)
        c.drawString(54, y, org)
        y -= 26
    c.setFillColor(INK)
    c.setFont("Helvetica-Bold", 17)
    c.drawString(54, y, title)
    y -= 18
    if subtitle:
        c.setFont("Helvetica", 10)
        c.setFillColor(GREY)
        c.drawString(54, y, subtitle)
        c.setFillColor(INK)
        y -= 14
    c.setStrokeColor(HexColor("#B9BFBC"))
    c.line(54, y, w - 54, y)
    return y - 24


def labelled(c, x, y, label, value, size=11, label_size=7.5, width=None):
    c.setFont("Helvetica", label_size)
    c.setFillColor(GREY)
    c.drawString(x, y + size + 2, label)
    c.setFillColor(INK)
    c.setFont("Helvetica", size)
    c.drawString(x, y, value)


def heading(c, y, text, x=54):
    c.setFont("Helvetica-Bold", 11.5)
    c.drawString(x, y, text)
    return y - 18


def para(c, y, text, x=54, width=500, size=10, leading=13.5):
    c.setFont("Helvetica", size)
    words, line = text.split(), ""
    for word in words:
        trial = (line + " " + word).strip()
        if c.stringWidth(trial, "Helvetica", size) > width:
            c.drawString(x, y, line)
            y -= leading
            line = word
        else:
            line = trial
    if line:
        c.drawString(x, y, line)
        y -= leading
    return y - 4


def table(c, y, headers, rows, widths, x=54, size=9.5, row_h=16):
    c.setFont("Helvetica-Bold", size)
    cx = x
    for head, wd in zip(headers, widths):
        c.drawString(cx + 3, y, head)
        cx += wd
    c.setStrokeColor(HexColor("#8C9490"))
    c.line(x, y - 5, x + sum(widths), y - 5)
    y -= row_h
    c.setFont("Helvetica", size)
    for row in rows:
        cx = x
        for cell, wd in zip(row, widths):
            c.drawString(cx + 3, y, cell)
            cx += wd
        c.setStrokeColor(HexColor("#D5DAD7"))
        c.line(x, y - 5, x + sum(widths), y - 5)
        y -= row_h
    return y - 6


def kv_rows(c, y, pairs, x=54, label_w=190, size=10, leading=17):
    for label, value in pairs:
        c.setFont("Helvetica", size - 1)
        c.setFillColor(GREY)
        c.drawString(x, y, label)
        c.setFillColor(INK)
        c.setFont("Helvetica", size)
        c.drawString(x + label_w, y, value)
        y -= leading
    return y - 6


# ------------------------------------------------------------------------------------------------ Cards

def photo_box(c, x, y, w, h, initials):
    c.setFillColor(HexColor("#D9DED9"))
    c.setStrokeColor(HexColor("#8A938D"))
    c.rect(x, y, w, h, fill=1, stroke=1)
    c.setFillColor(HexColor("#7D867F"))
    c.setFont("Helvetica-Bold", h / 4)
    c.drawCentredString(x + w / 2, y + h / 2 - h / 12, initials)
    c.setFillColor(INK)


def passport(c, doc, people):
    f = doc["fields"]
    W, H = 708, 498  # ICAO TD3 data page at 2x
    c.setPageSize((W, H))
    c.setFillColor(HexColor("#EDF0EA"))
    c.rect(0, 0, W, H, fill=1, stroke=0)
    watermark(c, W, H, 120)
    c.setFillColor(HexColor("#2C3E33"))
    c.setFont("Helvetica-Bold", 22)
    c.drawString(30, H - 42, "UTOPIA · PASSPORT / PASSEPORT")
    c.setFont("Helvetica", 11)
    c.drawString(30, H - 60, "Republic of Utopia · Type P · Code UTO")
    photo_box(c, 30, 150, 170, 220, "".join(p[0] for p in (f["givenNames"].split()[0], f["surname"])))
    rows = [
        ("Passport No. / No du passeport", f["documentNumber"]), ("Surname / Nom", f["surname"]),
        ("Given names / Prénoms", f["givenNames"]), ("Nationality / Nationalité", f["nationality"]),
        ("Date of birth / Date de naissance", icao(f["dateOfBirth"])), ("Sex / Sexe", f["sex"]),
        ("Place of birth / Lieu de naissance", f["placeOfBirth"]),
        ("Date of issue / Date de délivrance", icao(f["issueDate"])),
        ("Date of expiry / Date d'expiration", icao(f["expiryDate"])), ("Authority / Autorité", f["issuingAuthority"]),
    ]
    height = next((x["value"] for x in doc["details"] if x["label"] == "Height"), None)
    if height:
        rows.insert(7, ("Height / Taille", height))
    y = H - 100
    for label, value in rows:
        labelled(c, 225, y, label, value, size=13, label_size=8)
        y -= 31
    # MRZ
    sur, given = f["surname"], f["givenNames"].replace(" ", "<")
    l1 = (f"P<UTO{sur}<<{given}" + "<" * 44)[:44]
    num, dob, exp = f["documentNumber"], yymmdd(f["dateOfBirth"]), yymmdd(f["expiryDate"])
    l2 = num + check_digit(num) + "UTO" + dob + check_digit(dob) + f["sex"] + exp + check_digit(exp) + "<" * 14 + "0"
    l2 += check_digit(l2[0:10] + l2[13:20] + l2[21:43])
    c.setFillColor(black)
    c.setFont("Courier-Bold", 21)
    c.drawString(24, 58, l1)
    c.drawString(24, 26, l2)


def td1(code, number, dob, sex, exp, nationality, surname, given):
    """Three 30-character lines. Card numbers longer than 9 characters follow ICAO 9303's long-number rule:
    the first 9 in the number field, `<` where its check digit would be, the rest plus the check digit in the
    optional data."""
    if len(number) > 9:
        opt = number[9:] + check_digit(number)
        l1 = (code + "USA" + number[:9] + "<" + opt + "<" * 30)[:30]
    else:
        l1 = (code + "USA" + number + check_digit(number) + "<" * 30)[:30]
    l2 = dob + check_digit(dob) + sex + exp + check_digit(exp) + nationality + "<" * 11
    composite = l1[5:30] + l2[0:7] + l2[8:15] + l2[18:29]
    l2 += check_digit(composite)
    l3 = (f"{surname}<<{given.replace(' ', '<')}" + "<" * 30)[:30]
    return [l1, l2, l3]


def card_frame(c, x, y, w, h, fill):
    c.setFillColor(HexColor(fill))
    c.setStrokeColor(HexColor("#9AA39D"))
    c.roundRect(x, y, w, h, 18, fill=1, stroke=1)
    c.setFillColor(INK)


def immigration_card(c, doc, people, title, extra):
    f = doc["fields"]
    W, H = 540, 720
    c.setPageSize((W, H))
    c.setFillColor(HexColor("#F7F7F5"))
    c.rect(0, 0, W, H, fill=1, stroke=0)
    # Front
    fx, fy, cw, ch = 27, 380, 486, 306
    card_frame(c, fx, fy, cw, ch, "#E3EEE6" if doc["kind"] == "greenCard" else "#E9E6F2")
    c.setFont("Helvetica-Bold", 15)
    c.drawString(fx + 18, fy + ch - 30, f"SPECIMEN · {title}")
    photo_box(c, fx + 18, fy + 46, 112, 150, f["givenNames"][0] + f["surname"][0])
    col = fx + 148
    y = fy + ch - 66
    for label, value in extra + [
        ("Surname", f["surname"]), ("Given Name", f["givenNames"]),
        ("USCIS#", f["alienNumber"].replace("-", "")), ("Category", f["uscisCategory"]),
        ("Country of Birth", f["placeOfBirth"]), ("Date of Birth", us(f["dateOfBirth"])), ("Sex", f["sex"]),
    ]:
        labelled(c, col, y, label, value, size=11, label_size=7)
        y -= 25
    watermark(c, W, H, 100)
    # Back
    bx, by = 27, 34
    card_frame(c, bx, by, cw, ch, "#F1F1EC")
    c.setFont("Helvetica", 9)
    c.setFillColor(GREY)
    c.drawString(bx + 18, by + ch - 28, "SPECIMEN · BACK OF CARD · NOT A REAL DOCUMENT")
    c.setFillColor(INK)
    lines = td1(
        "C1" if doc["kind"] == "greenCard" else "IA", f["documentNumber"], yymmdd(f["dateOfBirth"]), f["sex"],
        yymmdd(f["expiryDate"]), "UTO", f["surname"], f["givenNames"],
    )
    c.setFont("Courier-Bold", 21)
    for i, line in enumerate(lines):
        c.drawString(bx + 18, by + 92 - i * 30, line)


def greencard(c, doc, people):
    f = doc["fields"]
    immigration_card(c, doc, people, "PERMANENT RESIDENT CARD", [
        ("Card Expires", us(f["expiryDate"])), ("Resident Since", us(f["residentSince"])), ("Card #", f["documentNumber"]),
    ])


def ead(c, doc, people):
    f = doc["fields"]
    immigration_card(c, doc, people, "EMPLOYMENT AUTHORIZATION CARD", [
        ("Valid From", us(f["validFrom"])), ("Card Expires", us(f["validUntil"])), ("Card #", f["documentNumber"]),
    ])


def aamva(doc):
    f = doc["fields"]
    street, city, rest = [p.strip() for p in f["address"].split(",")]
    state, zipcode = rest.split()
    first, *middle = f["givenNames"].split()
    body = "\n".join([
        f"DAQ{f['documentNumber']}", f"DCS{f['surname']}", f"DAC{first}", f"DAD{' '.join(middle) or 'NONE'}",
        f"DBD{us(f['issueDate']).replace('/', '')}", f"DBB{us(f['dateOfBirth']).replace('/', '')}",
        f"DBA{us(f['expiryDate']).replace('/', '')}", f"DBC{'2' if f['sex'] == 'F' else '1'}",
        f"DAG{street}", f"DAI{city}", f"DAJ{state}", f"DAK{zipcode}0000", "DCGUSA", f"DCF{doc['id'].upper()}",
    ])
    header = "@\n\x1e\rANSI 636000100002DL00410278ZW03190008DL"
    return header + body + "\r"


def dl(c, doc, people):
    f = doc["fields"]
    W, H = 540, 720
    c.setPageSize((W, H))
    c.setFillColor(HexColor("#F7F7F5"))
    c.rect(0, 0, W, H, fill=1, stroke=0)
    fx, fy, cw, ch = 27, 380, 486, 306
    card_frame(c, fx, fy, cw, ch, "#E2ECF3" if doc["state_code"] == "WA" else "#F3EEDF")
    c.setFont("Helvetica-Bold", 16)
    c.drawString(fx + 18, fy + ch - 30, f"SPECIMEN · {doc['state']}")
    c.setFont("Helvetica", 10)
    c.drawString(fx + 18, fy + ch - 46, "DRIVER LICENSE · USA")
    photo_box(c, fx + 18, fy + 40, 110, 150, f["givenNames"][0] + f["surname"][0])
    det = {x["label"]: x["value"] for x in doc["details"]}
    col = fx + 145
    rows = [
        ("4d DLN", f["documentNumber"]), ("1 " + "LN", f["surname"]), ("2 FN", f["givenNames"]),
        ("8", f["address"].split(",")[0]), ("", ", ".join(p.strip() for p in f["address"].split(",")[1:])),
    ]
    y = fy + ch - 70
    for label, value in rows:
        labelled(c, col, y, label, value, size=11, label_size=7)
        y -= 24
    grid = [("3 DOB", us(f["dateOfBirth"])), ("4b EXP", us(f["expiryDate"])), ("4a ISS", us(f["issueDate"])),
            ("9 CLASS", f["licenseClass"]), ("15 SEX", f["sex"]), ("16 HGT", det["Height"]), ("18 EYES", det["Eye colour"]),
            ("17 WGT", det["Weight"])]
    for i, (label, value) in enumerate(grid):
        labelled(c, col + (i % 3) * 112, y - (i // 3) * 26, label, value, size=10.5, label_size=7)
    watermark(c, W, H, 100)
    # Back with PDF417
    bx, by = 27, 34
    card_frame(c, bx, by, cw, ch, "#F1F1EC")
    c.setFont("Helvetica", 9)
    c.setFillColor(GREY)
    c.drawString(bx + 18, by + ch - 28, "SPECIMEN · BACK OF CARD · NOT A REAL DOCUMENT")
    codes = pdf417gen.encode(aamva(doc), columns=13, security_level=4)
    image = pdf417gen.render_image(codes, scale=3, ratio=3, padding=4)
    buffer = BytesIO()
    image.save(buffer, format="PNG")
    buffer.seek(0)
    c.drawImage(ImageReader(buffer), bx + 18, by + 40, width=cw - 36, height=190)


def ssn(c, doc, people):
    f = doc["fields"]
    W, H = 486, 306
    c.setPageSize((W, H))
    card_frame(c, 0, 0, W, H, "#EAF1F7")
    c.setFont("Helvetica-Bold", 15)
    c.drawCentredString(W / 2, H - 40, "SPECIMEN · SOCIAL SECURITY")
    c.setFont("Helvetica", 9)
    c.drawCentredString(W / 2, H - 56, "NOT A REAL CARD · ADVERTISING-RESERVED NUMBER")
    c.setFont("Helvetica-Bold", 24)
    c.drawCentredString(W / 2, H - 120, f["documentNumber"])
    c.setFont("Helvetica", 9)
    c.drawCentredString(W / 2, H - 140, "THIS NUMBER HAS BEEN ESTABLISHED FOR")
    c.setFont("Helvetica-Bold", 16)
    c.drawCentredString(W / 2, H - 170, f"{f['givenNames']} {f['surname']}")
    c.line(120, 60, W - 120, 60)
    c.setFont("Helvetica", 8)
    c.drawCentredString(W / 2, 48, "SIGNATURE")
    watermark(c, W, H, 70)


def insurance(c, doc, people):
    f = doc["fields"]
    e = {x["label"]: x["value"] for x in doc["contents"]}
    W, H = 486, 640
    c.setPageSize((W, H))
    c.setFillColor(HexColor("#F7F7F5"))
    c.rect(0, 0, W, H, fill=1, stroke=0)
    card_frame(c, 0, 334, W, 306, "#E4F0EE")
    c.setFont("Helvetica-Bold", 16)
    c.drawString(18, 334 + 270, "Cascade Mutual Health")
    c.setFont("Helvetica", 10)
    c.drawString(18, 334 + 254, "Evergreen PPO · SPECIMEN")
    y = 334 + 220
    for label, value in [("Member", f"{f['givenNames']} {f['surname']}"), ("Member ID", f["documentNumber"]),
                         ("Group", e["Group number"]), ("Effective", us(e["Effective date"])),
                         ("Dependents", "DAVID CHEN · EMMA CHEN")]:
        labelled(c, 18, y, label, value, size=12, label_size=7.5)
        y -= 30
    c.setFont("Helvetica", 9)
    c.drawString(300, 334 + 180, f"RxBIN  {e['Rx BIN']}")
    c.drawString(300, 334 + 166, f"RxPCN  {e['Rx PCN']}")
    c.drawString(300, 334 + 152, "RxGRP  0047731")
    c.drawString(300, 334 + 120, "PCP $25 · SPEC $50")
    c.drawString(300, 334 + 106, "ER $250")
    watermark(c, W, H, 90)
    card_frame(c, 0, 0, W, 306, "#F1F1EC")
    y = para(c, 270, "Member services 1-800-555-0199 · Providers 1-800-555-0198 · Nurse line 1-800-555-0197", x=18, width=450)
    y = para(c, y, "This card does not guarantee coverage. Present it to your provider at each visit. "
             "SPECIMEN FOR TESTING · NOT A REAL INSURANCE CARD · ALL DATA IS FICTIONAL.", x=18, width=450)


# ------------------------------------------------------------------------------------------------ Letters and forms

def i797(c, doc, people):
    f = doc["fields"]
    e = {x["label"]: x["value"] for x in doc["contents"]}
    y = letter_page(c, "SPECIMEN · Notice of Action (I-797)", "Fictional notice for testing · not issued by any agency",
                    org="SPECIMEN IMMIGRATION SERVICES")
    pairs = [("Receipt Number", f["receiptNumber"]), ("Case Type", e["Case type"]), ("Received Date", us(e["Received date"])),
             ("Priority Date", us(e["Priority date"])), ("Notice Date", us(f["noticeDate"])), ("Page", "1 of 1")]
    y = kv_rows(c, y, pairs, label_w=110)
    y = kv_rows(c, y, [("Applicant", f"{f['surname']}, {f['givenNames']}"), ("A#", f["alienNumber"]),
                       ("Date of Birth", us(f["dateOfBirth"])), ("Class", f["uscisCategory"])], label_w=110)
    y = heading(c, y - 6, e["Notice type"])
    y = kv_rows(c, y, [("Section", e["Section"]), ("Valid from", us(e["Valid from"]))], label_w=110)
    y = para(c, y, "The above application has been approved. You have been granted lawful permanent residence as of the "
             "date shown above. You will receive your new permanent resident card in a separate mailing. Please notify "
             "us if your address changes.")
    y = para(c, y - 6, f"{e['Service center']} · SPECIMEN · This notice is made up for software testing.")


def i94(c, doc, people):
    f = doc["fields"]
    y = letter_page(c, "SPECIMEN · Most Recent I-94 and Travel History", "Fictional record for testing")
    y = kv_rows(c, y, [("Admission I-94 Record Number", f["i94Number"]), ("Most Recent Date of Entry", us(doc["contents"][0]["value"])),
                       ("Class of Admission", f["classOfAdmission"]), ("Admit Until Date", us(f["admitUntil"])),
                       ("Last/Surname", f["surname"]), ("First (Given) Name", f["givenNames"]),
                       ("Birth Date", us(f["dateOfBirth"])), ("Document Number", f["documentNumber"]),
                       ("Country of Citizenship", "Utopia")], label_w=200)
    y = heading(c, y - 4, "Travel History")
    rows = [[str(i + 1), date, "Arrival" if kind == "arrival" else "Departure", port] for i, (date, kind, port) in enumerate(doc["travel"])]
    table(c, y, ["#", "Date", "Type", "Location"], rows, [40, 120, 120, 120])


def lease(c, doc, people):
    f, L = doc["fields"], doc["lease"]
    y = letter_page(c, "RESIDENTIAL LEASE AGREEMENT", "SPECIMEN · made-up lease for testing")
    tenants = " and ".join(L["tenants"])
    y = para(c, y, f'This lease is made on {long(L["signed"])} between {L["landlord"]} ("Landlord") and {tenants} ("Tenant").')
    y = heading(c, y, "1. Premises")
    y = para(c, y, f"The Landlord rents to the Tenant the residence at {f['address']}.")
    y = heading(c, y, "2. Term")
    y = para(c, y, f"The term begins on {long(f['leaseStartDate'])} and ends on {long(f['leaseEndDate'])}.")
    y = heading(c, y, "3. Rent")
    y = para(c, y, f"Monthly rent is {L['rent']}, due on the first day of each month. A late fee of $75.00 applies after the fifth day.")
    y = heading(c, y, "4. Security deposit")
    y = para(c, y, f"The Tenant has paid a security deposit of {L['deposit']}, refundable under state law.")
    y = heading(c, y, "5. Parking and pets")
    y = para(c, y, f"Parking: {L['parking']}. Pets: {L['pets']}.")
    y = heading(c, y, "6. Utilities")
    y = para(c, y, "Tenant pays electricity and internet. Landlord pays water, sewer and garbage.")
    y = heading(c, y, "7. Notices")
    y = para(c, y, f"Property manager: {L['landlord']}, {L['manager_phone']}.")
    c.showPage()
    w, h = letter
    watermark(c, w, h, 110)
    footer(c, w)
    y = heading(c, h - 72, "8. Tenant contact information")
    y = kv_rows(c, y, [("Tenant", tenants), ("Phone", L["phone"]), ("Email", L["email"])], label_w=90)
    y = heading(c, y, "9. Signatures")
    y = kv_rows(c, y, [("Landlord", L["landlord"])] + [("Tenant", t) for t in L["tenants"]] + [("Date signed", us(L["signed"]))], label_w=90)


def termination(c, doc, people):
    e = {x["label"]: x["value"] for x in doc["contents"]}
    y = letter_page(c, "ADDENDUM: EARLY TERMINATION OF LEASE", "SPECIMEN · made-up addendum for testing")
    y = kv_rows(c, y, [("Date of this addendum", us(doc["fields"]["issueDate"])), ("Premises", doc["fields"]["address"]),
                       ("Landlord", e["Landlord"]), ("Tenants", "Anna Maria Eriksson and David Lee Chen"),
                       ("Original lease term", f"01/01/2023 to {us(e['Original lease end'])}")], label_w=150)
    y = para(c, y, f"Landlord and Tenants agree that the lease for the premises above will end early on {long(e['Lease ends early on'])}. "
             f"Tenants will pay a termination fee of {e['Termination fee']} and return all keys by that date. All other "
             "terms of the lease stay in effect until then.")
    kv_rows(c, y - 20, [("Landlord", "Pine Avenue Homes, by M. Ortiz"), ("Tenant", "Anna Maria Eriksson"), ("Tenant", "David Lee Chen")], label_w=90)


def vaccines_page(c, doc, people, title, org):
    f = doc["fields"]
    y = letter_page(c, title, "SPECIMEN · made-up record for testing", org=org)
    y = kv_rows(c, y, [("Name", f"{f['surname']}, {f['givenNames']}"), ("Date of birth", us(f["dateOfBirth"]))], label_w=90)
    for x in doc.get("contents_extra", []):
        y = kv_rows(c, y, [(x["label"], x["value"])], label_w=90)
    rows = [[name, dose, us(dt), lot, place] for name, dose, dt, lot, place in doc["vaccines"]]
    table(c, y - 4, ["Vaccine", "Dose", "Date given", "Lot", "Given at"], rows, [130, 55, 75, 60, 190], size=9)


def vaxcard(c, doc, people):
    vaccines_page(c, doc, people, "International Certificate of Vaccination", "SPECIMEN HEALTH RECORD")


def kidvax(c, doc, people):
    vaccines_page(c, doc, people, "Childhood Immunization Record", "ROSE CITY PEDIATRICS · SPECIMEN")
    c.setFont("Helvetica", 9)
    c.drawString(54, 120, f"Printed {us(doc['fields']['issueDate'])} · Record reviewed by Dr. Alicia Moreno")


def i693(c, doc, people):
    f = doc["fields"]
    e = {x["label"]: x["value"] for x in doc["contents"]}
    y = letter_page(c, "SPECIMEN · Report of Immigration Medical Examination (I-693)", "Fictional form for testing · page 1 of 3")
    y = heading(c, y, "Part 1. Applicant")
    y = kv_rows(c, y, [("Family name", f["surname"]), ("Given name", f["givenNames"]), ("Date of birth", us(f["dateOfBirth"])),
                       ("Phone", "(206) 555-0142"), ("Address", "412 Alder St, Apt 3B, Seattle, WA 98101")], label_w=120)
    y = heading(c, y, "Part 4. Civil surgeon")
    kv_rows(c, y, [("Name", e["Name"]), ("Practice", e["Practice"]), ("Exam date", us(e["Exam date"]))], label_w=120)
    c.showPage()
    y = letter_page(c, "Part 5. Medical examination", "page 2 of 3")
    y = heading(c, y, "Tuberculosis")
    y = table(c, y, ["Test", "Date", "Result"], [["IGRA (QuantiFERON)", us("2020-02-20"), "Negative"],
                                                 ["Chest X-ray", "", "Not required"]], [200, 100, 150])
    y = heading(c, y, "Syphilis")
    y = table(c, y, ["Test", "Date", "Result"], [["RPR", us("2020-02-20"), "Nonreactive"]], [200, 100, 150])
    y = heading(c, y, "Gonorrhea")
    table(c, y, ["Test", "Date", "Result"], [["NAAT", us("2020-02-20"), "Negative"]], [200, 100, 150])
    c.showPage()
    y = letter_page(c, "Part 6. Vaccination record", "page 3 of 3")
    table(c, y, ["Vaccine", "Date", "Status", "Lot"], [
        ["Td/Tdap", us("2020-02-20"), "Given today", "TD8812"], ["MMR", us("1995-08-20"), "Documented", ""],
        ["Hepatitis B", us("2008-07-14"), "Documented", ""], ["Varicella", us("2020-02-20"), "Immune (titer)", ""],
        ["Influenza", "", "Not in season, waived", ""]], [150, 90, 150, 80])


def labs(c, doc, people):
    f = doc["fields"]
    y = letter_page(c, "Laboratory Report", "SPECIMEN · made-up results for testing", org="NORTHWEST FAMILY MEDICINE")
    y = kv_rows(c, y, [("Patient", f"{f['surname']}, {f['givenNames']}"), ("DOB", us(f["dateOfBirth"])),
                       ("Collected", us(f["issueDate"])), ("Ordering provider", "Dr. Marcus Webb, MD")], label_w=120)
    rows = [
        ["Lipid panel", "Total cholesterol", "182", "mg/dL", "<200", ""], ["", "LDL cholesterol", "104", "mg/dL", "<100", "H"],
        ["", "HDL cholesterol", "61", "mg/dL", ">39", ""], ["", "Triglycerides", "86", "mg/dL", "<150", ""],
        ["Diabetes", "Hemoglobin A1c", "5.4", "%", "<5.7", ""], ["Vitamins", "Vitamin D, 25-OH", "32", "ng/mL", "30-100", ""],
        ["Thyroid", "TSH", "1.9", "mIU/L", "0.4-4.0", ""], ["Blood count", "Hemoglobin", "13.2", "g/dL", "12.0-15.5", ""],
    ]
    table(c, y, ["Panel", "Test", "Result", "Units", "Reference", "Flag"], rows, [90, 140, 60, 60, 80, 40])


def w2(c, doc, people):
    e = {x["label"]: x["value"] for x in doc["contents"]}
    f = doc["fields"]
    y = letter_page(c, "SPECIMEN · Form W-2 Wage and Tax Statement 2025", "Made-up form for testing · not filed")
    y = kv_rows(c, y, [("a Employee's social security number", e["Social Security number"]),
                       ("b Employer identification number (EIN)", e["Employer ID number (EIN)"]),
                       ("c Employer's name, address", f"{e['Employer']}, {e['Employer address']}"),
                       ("e Employee's name", f"{f['givenNames']} {f['surname']}"), ("f Employee's address", f["address"])], label_w=210)
    rows = [[k.split(" · ")[0], k.split(" · ")[1], v] for k, v in e.items() if k.startswith("Box")]
    table(c, y, ["Box", "Description", "Amount"], rows, [60, 260, 120])


def marriage(c, doc, people):
    e = {x["label"]: x["value"] for x in doc["contents"]}
    y = letter_page(c, "CERTIFICATE OF MARRIAGE", "SPECIMEN · Kingsley County, Washington · made-up record", org="KINGSLEY COUNTY RECORDER · SPECIMEN")
    y = kv_rows(c, y, [("Certificate number", e["Certificate number"]), ("Date of marriage", long(e["Date of marriage"])),
                       ("Place of marriage", e["Place of marriage"])], label_w=150)
    y = heading(c, y, "Spouse 1")
    y = kv_rows(c, y, [("Name", "Anna Maria Eriksson"), ("Date of birth", long("1990-08-12")), ("Birthplace", "Lumen City, Utopia"),
                       ("Father", "Lars Eriksson"), ("Mother (maiden name)", "Ingrid Eriksson, born Holm")], label_w=150)
    y = heading(c, y, "Spouse 2")
    y = kv_rows(c, y, [("Name", "David Lee Chen"), ("Date of birth", long("1988-03-05")), ("Birthplace", "Harbor Town, Utopia"),
                       ("Father", "Wei Chen"), ("Mother (maiden name)", "Linda Chen, born Wu")], label_w=150)
    y = kv_rows(c, y, [("Officiant", e["Officiant"]), ("Witnesses", "Sofia Lindqvist, Kevin Park"),
                       ("Recorded", long(doc["fields"]["issueDate"]))], label_w=150)


def birth(c, doc, people):
    f = doc["fields"]
    e = {x["label"]: x["value"] for x in doc["contents"]}
    y = letter_page(c, "CERTIFICATE OF LIVE BIRTH", "SPECIMEN · Kingsley County · made-up record for testing", org="KINGSLEY COUNTY VITAL RECORDS · SPECIMEN")
    y = kv_rows(c, y, [("Certificate number", f["documentNumber"]), ("Child's name", "Emma Lin Chen"), ("Sex", "Female"),
                       ("Date of birth", long(f["dateOfBirth"])), ("Time of birth", e["Time of birth"]),
                       ("Place of birth", f"{e['Facility']}, Seattle, Washington"), ("County", e["County"])], label_w=150)
    y = heading(c, y, "Mother")
    y = kv_rows(c, y, [("Name", "Anna Maria Eriksson"), ("Date of birth", long("1990-08-12")), ("Birthplace", "Utopia"),
                       ("Residence", "412 Alder St, Apt 3B, Seattle, WA 98101")], label_w=150)
    y = heading(c, y, "Father")
    y = kv_rows(c, y, [("Name", "David Lee Chen"), ("Date of birth", long("1988-03-05")), ("Birthplace", "Utopia")], label_w=150)
    kv_rows(c, y, [("Local registrar", e["Local registrar"]), ("Date filed", long(e["Date filed"])),
                   ("Date issued", long(f["issueDate"]))], label_w=150)


TEMPLATES = {name: fn for name, fn in globals().items() if callable(fn) and name in {
    "passport", "greencard", "ead", "dl", "ssn", "insurance", "i797", "i94", "lease", "termination", "vaxcard",
    "kidvax", "i693", "labs", "w2", "marriage", "birth"}}


def render(doc, people, path):
    c = canvas.Canvas(path, pagesize=letter)
    c.setTitle(f"SPECIMEN · {doc['file']}")
    TEMPLATES[doc["template"]](c, doc, people)
    c.showPage()
    c.save()
