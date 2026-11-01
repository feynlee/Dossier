"""The made-up Eriksson-Chen household: every document's ground truth, and the questions Siri should answer.

Everyone, every number, every address and every organisation here is invented. Countries are the ICAO specimen
country "Utopia" (code UTO). SSNs are in the 987-65-432x range, which the SSA reserves for advertising and never
issues. Phone numbers use the fictional 555-01xx range. Every rendered page says SPECIMEN.

Values in `fields` use the app's FactKey names and the app's formats: dates YYYY-MM-DD, names as printed.
`contents` and `details` are what a complete reading should also find; `important` marks the ones a person is
likely to ask about, which weigh more in the completeness score.
"""

TODAY = "2026-10-31"

PEOPLE = {
    "anna": {"name": "Anna Maria Eriksson", "relation": "self", "dob": "1990-08-12"},
    "david": {"name": "David Lee Chen", "relation": "spouse", "dob": "1988-03-05"},
    "emma": {"name": "Emma Lin Chen", "relation": "child", "dob": "2021-11-03"},
}


def entry(section, label, value, important=False):
    return {"section": section, "label": label, "value": value, "important": important}


def detail(label, value, person="holder", person_name="", important=False):
    return {"person": person, "personName": person_name, "label": label, "value": value, "important": important}


DOCUMENTS = [
    # ---------------------------------------------------------------- Anna: identity
    {
        "id": "anna-passport-2009", "holder": "anna", "kind": "passport", "template": "passport",
        "file": "Anna · Passport 2009 (expired)", "variants": ["clean"],
        "fields": {
            "surname": "ERIKSSON", "givenNames": "ANNA MARIA", "nationality": "UTOPIAN", "dateOfBirth": "1990-08-12",
            "placeOfBirth": "LUMEN CITY", "sex": "F", "documentNumber": "PX1938457", "issueDate": "2009-03-16",
            "expiryDate": "2019-03-15", "issuingAuthority": "PASSPORT OFFICE UTOPIA",
        },
        "details": [detail("Height", "168 cm")],
    },
    {
        "id": "anna-passport-2019", "holder": "anna", "kind": "passport", "template": "passport",
        "file": "Anna · Passport 2019", "variants": ["clean", "photo", "lowres"],
        "fields": {
            "surname": "ERIKSSON", "givenNames": "ANNA MARIA", "nationality": "UTOPIAN", "dateOfBirth": "1990-08-12",
            "placeOfBirth": "LUMEN CITY", "sex": "F", "documentNumber": "PX7204821", "issueDate": "2019-03-15",
            "expiryDate": "2029-03-14", "issuingAuthority": "PASSPORT OFFICE UTOPIA",
        },
        "details": [detail("Height", "168 cm")],
    },
    {
        "id": "anna-ead-2020", "holder": "anna", "kind": "employmentAuthorization", "template": "ead",
        "file": "Anna · EAD card 2020", "variants": ["clean"],
        "fields": {
            "surname": "ERIKSSON", "givenNames": "ANNA MARIA", "dateOfBirth": "1990-08-12", "placeOfBirth": "UTOPIA",
            "sex": "F", "alienNumber": "204-815-962", "uscisCategory": "C09", "documentNumber": "SRC2090123456",
            "validFrom": "2020-05-01", "validUntil": "2021-04-30", "expiryDate": "2021-04-30",
        },
    },
    {
        "id": "anna-greencard", "holder": "anna", "kind": "greenCard", "template": "greencard",
        "file": "Anna · Green card", "variants": ["clean", "photo"],
        "fields": {
            "surname": "ERIKSSON", "givenNames": "ANNA MARIA", "dateOfBirth": "1990-08-12", "placeOfBirth": "UTOPIA",
            "sex": "F", "alienNumber": "204-815-962", "uscisCategory": "E21", "residentSince": "2021-03-02",
            "documentNumber": "SRC2190456789", "expiryDate": "2031-03-01",
        },
    },
    {
        "id": "anna-i797-i485", "holder": "anna", "kind": "uscisNotice", "template": "i797",
        "file": "Anna · I-485 approval notice", "variants": ["clean", "scan"],
        "fields": {
            "surname": "ERIKSSON", "givenNames": "ANNA MARIA", "dateOfBirth": "1990-08-12", "alienNumber": "A204815962",
            "formType": "I-485", "receiptNumber": "MSC2190312345", "noticeDate": "2021-03-05", "uscisCategory": "E21",
        },
        "contents": [
            entry("Notice", "Notice type", "Approval Notice", True),
            entry("Notice", "Received date", "2020-03-10", True),
            entry("Notice", "Priority date", "2019-11-04", True),
            entry("Notice", "Case type", "I-485 Application to Register Permanent Residence or Adjust Status"),
            entry("Notice", "Section", "Employment-based second preference (E21)"),
            entry("Notice", "Valid from", "2021-03-02"),
            entry("Notice", "Service center", "National Benefits Center"),
        ],
    },
    {
        "id": "anna-i94", "holder": "anna", "kind": "i94", "template": "i94",
        "file": "Anna · I-94 travel history", "variants": ["clean"],
        "fields": {
            "surname": "ERIKSSON", "givenNames": "ANNA MARIA", "dateOfBirth": "1990-08-12", "i94Number": "93847561020",
            "classOfAdmission": "H1B", "admitUntil": "2022-09-30", "documentNumber": "PX7204821",
        },
        "contents": [entry("Most recent I-94", "Most recent date of entry", "2019-10-02", True)],
        "travel": [
            ("2025-03-22", "arrival", "SEA"), ("2025-03-10", "departure", "PDX"), ("2024-08-25", "arrival", "SEA"),
            ("2024-08-09", "departure", "SEA"), ("2023-04-16", "arrival", "PDX"), ("2023-04-07", "departure", "PDX"),
            ("2021-07-03", "arrival", "SEA"), ("2021-06-12", "departure", "SEA"), ("2019-10-02", "arrival", "SEA"),
        ],
    },
    {
        "id": "anna-dl-wa-2020", "holder": "anna", "kind": "driversLicense", "template": "dl",
        "file": "Anna · Washington driver's licence 2020", "variants": ["clean", "photo"],
        "state": "WASHINGTON", "state_code": "WA",
        "fields": {
            "surname": "ERIKSSON", "givenNames": "ANNA M", "dateOfBirth": "1990-08-12", "sex": "F",
            "address": "412 ALDER ST APT 3B, SEATTLE, WA 98101", "documentNumber": "WDLERIKSA902",
            "licenseClass": "C", "issueDate": "2020-09-01", "expiryDate": "2026-08-12",
        },
        "details": [detail("Height", "5'-06\"", important=True), detail("Eye colour", "BRN", important=True),
                    detail("Weight", "135 lb")],
    },
    {
        "id": "anna-dl-or-2023", "holder": "anna", "kind": "driversLicense", "template": "dl",
        "file": "Anna · Oregon driver's licence 2023", "variants": ["clean"],
        "state": "OREGON", "state_code": "OR",
        "fields": {
            "surname": "ERIKSSON", "givenNames": "ANNA MARIA", "dateOfBirth": "1990-08-12", "sex": "F",
            "address": "88 PINE AVE, PORTLAND, OR 97205", "documentNumber": "7812345",
            "licenseClass": "C", "issueDate": "2023-03-20", "expiryDate": "2031-08-12",
        },
        "details": [detail("Height", "5'-06\"", important=True), detail("Eye colour", "BRN", important=True),
                    detail("Weight", "135 lb")],
    },
    {
        "id": "anna-ssn-card", "holder": "anna", "kind": "other", "template": "ssn",
        "file": "Anna · Social Security card", "variants": ["photo"],
        "fields": {"surname": "ERIKSSON", "givenNames": "ANNA MARIA", "documentNumber": "987-65-4321"},
        "contents": [entry("Card", "Social Security number", "987-65-4321", True)],
    },
    # ---------------------------------------------------------------- Housing
    {
        "id": "lease-2020-alder", "holder": "anna", "kind": "lease", "template": "lease",
        "file": "Lease 2020 · 412 Alder St", "variants": ["clean"],
        "fields": {"address": "412 Alder St, Apt 3B, Seattle, WA 98101", "leaseStartDate": "2020-08-01", "leaseEndDate": "2022-07-31"},
        "lease": {"landlord": "Alder Street Apartments LLC", "tenants": ["Anna Maria Eriksson"], "rent": "$2,150.00",
                  "deposit": "$2,150.00", "signed": "2020-07-15", "phone": "(206) 555-0142", "email": "anna.eriksson@example.com",
                  "manager_phone": "(206) 555-0170", "parking": "None", "pets": "No pets"},
        "contents": [
            entry("Rent", "Monthly rent", "$2,150.00", True), entry("Rent", "Security deposit", "$2,150.00", True),
            entry("Parties", "Landlord", "Alder Street Apartments LLC", True), entry("Parties", "Tenant", "Anna Maria Eriksson"),
            entry("Signatures", "Signed", "2020-07-15"),
        ],
        "details": [detail("Phone", "(206) 555-0142", important=True), detail("Email", "anna.eriksson@example.com", important=True)],
    },
    {
        "id": "lease-2023-pine", "holder": "anna", "kind": "lease", "template": "lease",
        "file": "Lease 2023 · 88 Pine Ave", "variants": ["clean"],
        "fields": {"address": "88 Pine Ave, Portland, OR 97205", "leaseStartDate": "2023-01-01", "leaseEndDate": "2027-12-31"},
        "lease": {"landlord": "Pine Avenue Homes", "tenants": ["Anna Maria Eriksson", "David Lee Chen"], "rent": "$2,480.00",
                  "deposit": "$3,000.00", "signed": "2022-12-02", "phone": "(503) 555-0188", "email": "anna.eriksson@example.com",
                  "manager_phone": "(503) 555-0110", "parking": "One assigned space, #14", "pets": "One cat permitted"},
        "contents": [
            entry("Rent", "Monthly rent", "$2,480.00", True), entry("Rent", "Security deposit", "$3,000.00", True),
            entry("Parties", "Landlord", "Pine Avenue Homes", True), entry("Parties", "Tenant", "Anna Maria Eriksson"),
            entry("Parties", "Tenant", "David Lee Chen"), entry("Terms", "Parking", "One assigned space, #14"),
            entry("Terms", "Pets", "One cat permitted"), entry("Signatures", "Signed", "2022-12-02"),
        ],
        "details": [detail("Phone", "(503) 555-0188", important=True), detail("Email", "anna.eriksson@example.com")],
    },
    {
        "id": "lease-2023-pine-termination", "holder": "anna", "kind": "other", "template": "termination",
        "file": "Lease 2023 · early termination addendum", "variants": ["scan"],
        "fields": {"address": "88 Pine Ave, Portland, OR 97205", "issueDate": "2026-05-15"},
        "contents": [
            entry("Termination", "Lease ends early on", "2026-06-30", True),
            entry("Termination", "Original lease end", "2027-12-31"),
            entry("Termination", "Termination fee", "$2,480.00"),
            entry("Parties", "Landlord", "Pine Avenue Homes"),
        ],
    },
    {
        "id": "lease-2026-lovejoy", "holder": "anna", "kind": "lease", "template": "lease",
        "file": "Lease 2026 · 1720 NW Lovejoy St", "variants": ["clean", "scan"],
        "fields": {"address": "1720 NW Lovejoy St, Apt 210, Portland, OR 97209", "leaseStartDate": "2026-07-01", "leaseEndDate": "2027-06-30"},
        "lease": {"landlord": "Lovejoy Lofts LLC", "tenants": ["Anna Maria Eriksson", "David Lee Chen"], "rent": "$2,950.00",
                  "deposit": "$2,950.00", "signed": "2026-06-04", "phone": "(503) 555-0188", "email": "anna.eriksson@example.com",
                  "manager_phone": "(503) 555-0133", "parking": "Garage space G-07, $150.00 per month", "pets": "One cat permitted, pet rent $35.00 per month"},
        "contents": [
            entry("Rent", "Monthly rent", "$2,950.00", True), entry("Rent", "Security deposit", "$2,950.00", True),
            entry("Parties", "Landlord", "Lovejoy Lofts LLC", True), entry("Parties", "Tenant", "Anna Maria Eriksson"),
            entry("Parties", "Tenant", "David Lee Chen"), entry("Terms", "Parking", "Garage space G-07, $150.00 per month", True),
            entry("Terms", "Pets", "One cat permitted, pet rent $35.00 per month"), entry("Signatures", "Signed", "2026-06-04"),
        ],
        "details": [detail("Phone", "(503) 555-0188", important=True), detail("Email", "anna.eriksson@example.com")],
    },
    # ---------------------------------------------------------------- Anna: health
    {
        "id": "anna-vaccination-card", "holder": "anna", "kind": "other", "template": "vaxcard",
        "file": "Anna · Vaccination record", "variants": ["clean", "photo"],
        "fields": {"surname": "ERIKSSON", "givenNames": "ANNA MARIA", "dateOfBirth": "1990-08-12"},
        "vaccines": [
            ("MMR", "dose 1", "1991-09-02", "M1123", "Lumen City Health Office"),
            ("MMR", "dose 2", "1995-08-20", "M2290", "Lumen City Health Office"),
            ("Hepatitis B", "dose 1", "2008-01-15", "HB301", "Lumen City Health Office"),
            ("Hepatitis B", "dose 2", "2008-02-19", "HB377", "Lumen City Health Office"),
            ("Hepatitis B", "dose 3", "2008-07-14", "HB415", "Lumen City Health Office"),
            ("Tdap", "", "2015-09-14", "TD4471", "Lumen City Health Office"),
            ("COVID-19 (Moderna)", "dose 1", "2021-04-10", "MD0391", "Seattle Mass Vaccination Site"),
            ("COVID-19 (Moderna)", "dose 2", "2021-05-08", "MD0457", "Seattle Mass Vaccination Site"),
            ("COVID-19 (Moderna)", "booster", "2023-10-02", "MD2210", "Pine Pharmacy"),
            ("Influenza", "", "2025-10-12", "FL2581", "Pine Pharmacy"),
        ],
    },
    {
        "id": "anna-i693", "holder": "anna", "kind": "other", "template": "i693",
        "file": "Anna · Medical exam I-693", "variants": ["clean", "scan"],
        "fields": {"surname": "ERIKSSON", "givenNames": "ANNA MARIA", "dateOfBirth": "1990-08-12", "formType": "I-693", "issueDate": "2020-02-20"},
        "contents": [
            entry("Civil surgeon", "Name", "Dr. Priya Raman, MD", True),
            entry("Civil surgeon", "Practice", "Harbor Civil Surgeon Clinic, 220 Elliott Ave W, Seattle, WA 98119"),
            entry("Tuberculosis", "IGRA test", "QuantiFERON · 2020-02-20 · Negative", True),
            entry("Tuberculosis", "Chest X-ray", "Not required"),
            entry("Syphilis", "Screening test", "RPR · 2020-02-20 · Nonreactive", True),
            entry("Gonorrhea", "NAAT", "2020-02-20 · Negative"),
            entry("Vaccinations", "Td/Tdap", "2020-02-20 · Lot TD8812 · Given today", True),
            entry("Vaccinations", "MMR", "Documented · 1995-08-20"),
            entry("Vaccinations", "Hepatitis B", "Documented · 2008-07-14"),
            entry("Vaccinations", "Varicella", "Immune · titer 2020-02-20"),
            entry("Vaccinations", "Influenza", "Not in season · waived"),
            entry("Exam", "Exam date", "2020-02-20", True),
        ],
        "details": [detail("Phone", "(206) 555-0142")],
    },
    {
        "id": "anna-labs-2026", "holder": "anna", "kind": "other", "template": "labs",
        "file": "Anna · Lab results April 2026", "variants": ["clean"],
        # Deliberate typo: the clinic printed the birth date with day and month digits swapped (08-21 for 08-12).
        "fields": {"surname": "ERIKSSON", "givenNames": "ANNA", "dateOfBirth": "1990-08-21", "issueDate": "2026-04-18"},
        "contents": [
            entry("Report", "Collected", "2026-04-18", True), entry("Report", "Ordering provider", "Dr. Marcus Webb, MD", True),
            entry("Report", "Clinic", "Northwest Family Medicine"),
            entry("Lipid panel", "Total cholesterol", "182 mg/dL · <200", True),
            entry("Lipid panel", "LDL cholesterol", "104 mg/dL · <100 · High", True),
            entry("Lipid panel", "HDL cholesterol", "61 mg/dL · >39", True),
            entry("Lipid panel", "Triglycerides", "86 mg/dL · <150"),
            entry("Diabetes", "Hemoglobin A1c", "5.4 % · <5.7", True),
            entry("Vitamins", "Vitamin D, 25-OH", "32 ng/mL · 30-100", True),
            entry("Thyroid", "TSH", "1.9 mIU/L · 0.4-4.0"),
            entry("Blood count", "Hemoglobin", "13.2 g/dL · 12.0-15.5"),
        ],
    },
    {
        "id": "anna-insurance-card", "holder": "anna", "kind": "other", "template": "insurance",
        "file": "Anna · Health insurance card", "variants": ["clean", "photo"],
        # The insurer has her married name.
        "fields": {"surname": "ERIKSSON-CHEN", "givenNames": "ANNA", "documentNumber": "ZXA884512703", "issueDate": "2026-01-01"},
        "contents": [
            entry("Card", "Member ID", "ZXA884512703", True), entry("Card", "Group number", "0047731", True),
            entry("Card", "Plan", "Evergreen PPO", True), entry("Card", "Insurer", "Cascade Mutual Health", True),
            entry("Card", "Effective date", "2026-01-01"), entry("Card", "Rx BIN", "999001"), entry("Card", "Rx PCN", "CMHRX"),
            entry("Copays", "Primary care", "$25"), entry("Copays", "Specialist", "$50"), entry("Copays", "Emergency room", "$250"),
            entry("Contacts", "Member services", "1-800-555-0199"),
            entry("Dependents", "Dependent", "David Chen"), entry("Dependents", "Dependent", "Emma Chen"),
        ],
    },
    # ---------------------------------------------------------------- Anna: money and family
    {
        "id": "anna-w2-2025", "holder": "anna", "kind": "other", "template": "w2",
        "file": "Anna · W-2 2025", "variants": ["clean"],
        "fields": {"surname": "ERIKSSON", "givenNames": "ANNA M", "address": "88 Pine Ave, Portland, OR 97205", "formType": "W-2"},
        "contents": [
            entry("Employee", "Social Security number", "987-65-4321", True),
            entry("Employer", "Employer", "Brightwater Analytics LLC", True),
            entry("Employer", "Employer ID number (EIN)", "98-7654321", True),
            entry("Employer", "Employer address", "500 SW Morrison St, Suite 900, Portland, OR 97204"),
            entry("Income", "Box 1 · Wages, tips, other compensation", "148,250.00", True),
            entry("Income", "Box 2 · Federal income tax withheld", "27,410.55", True),
            entry("Income", "Box 3 · Social security wages", "148,250.00"),
            entry("Income", "Box 4 · Social security tax withheld", "9,191.50"),
            entry("Income", "Box 5 · Medicare wages and tips", "148,250.00"),
            entry("Income", "Box 6 · Medicare tax withheld", "2,149.63"),
            entry("Income", "Box 12a · Code D", "23,000.00"),
            entry("State", "Box 16 · State wages", "148,250.00"), entry("State", "Box 17 · State income tax", "12,601.25", True),
            entry("Form", "Tax year", "2025", True),
        ],
        "details": [detail("Employer", "Brightwater Analytics LLC", important=True)],
    },
    {
        "id": "marriage-certificate", "holder": "anna", "kind": "other", "template": "marriage",
        "file": "Marriage certificate 2018", "variants": ["scan"],
        "fields": {"issueDate": "2018-07-02"},
        "contents": [
            entry("Marriage", "Date of marriage", "2018-06-23", True),
            entry("Marriage", "Place of marriage", "Seattle, Kingsley County, Washington", True),
            entry("Marriage", "Officiant", "Rev. Thomas Okafor"),
            entry("Marriage", "Certificate number", "2018-MC-031557", True),
            entry("Witnesses", "Witness", "Sofia Lindqvist"), entry("Witnesses", "Witness", "Kevin Park"),
        ],
        "details": [
            detail("Name", "Anna Maria Eriksson"), detail("Date of birth", "1990-08-12"),
            detail("Place of birth", "Lumen City, Utopia"),
            detail("Name", "David Lee Chen", "spouse", "David Lee Chen", True),
            detail("Date of birth", "1988-03-05", "spouse", "David Lee Chen"),
            detail("Place of birth", "Harbor Town, Utopia", "spouse", "David Lee Chen"),
            detail("Name", "Lars Eriksson", "father", "Lars Eriksson", True),
            detail("Name", "Ingrid Eriksson (born Holm)", "mother", "Ingrid Eriksson", True),
        ],
    },
    # ---------------------------------------------------------------- David
    {
        "id": "david-passport-2017", "holder": "david", "kind": "passport", "template": "passport",
        "file": "David · Passport 2017", "variants": ["clean"],
        "fields": {
            "surname": "CHEN", "givenNames": "DAVID LEE", "nationality": "UTOPIAN", "dateOfBirth": "1988-03-05",
            "placeOfBirth": "HARBOR TOWN", "sex": "M", "documentNumber": "PY5512093", "issueDate": "2017-07-01",
            "expiryDate": "2027-06-30", "issuingAuthority": "PASSPORT OFFICE UTOPIA",
        },
        "details": [detail("Height", "180 cm")],
    },
    {
        "id": "david-greencard", "holder": "david", "kind": "greenCard", "template": "greencard",
        "file": "David · Green card", "variants": ["clean"],
        "fields": {
            "surname": "CHEN", "givenNames": "DAVID LEE", "dateOfBirth": "1988-03-05", "placeOfBirth": "UTOPIA",
            "sex": "M", "alienNumber": "204-815-977", "uscisCategory": "E22", "residentSince": "2021-03-02",
            "documentNumber": "SRC2190456801", "expiryDate": "2031-03-01",
        },
    },
    {
        "id": "david-dl-or-2023", "holder": "david", "kind": "driversLicense", "template": "dl",
        "file": "David · Oregon driver's licence 2023", "variants": ["clean"],
        "state": "OREGON", "state_code": "OR",
        "fields": {
            "surname": "CHEN", "givenNames": "DAVID LEE", "dateOfBirth": "1988-03-05", "sex": "M",
            "address": "88 PINE AVE, PORTLAND, OR 97205", "documentNumber": "7812399",
            "licenseClass": "C", "issueDate": "2023-03-20", "expiryDate": "2031-03-05",
        },
        "details": [detail("Height", "5'-11\"", important=True), detail("Eye colour", "BLK", important=True),
                    detail("Weight", "172 lb")],
    },
    # ---------------------------------------------------------------- Emma
    {
        "id": "emma-birth-certificate", "holder": "emma", "kind": "other", "template": "birth",
        "file": "Emma · Birth certificate", "variants": ["clean", "scan"],
        "fields": {"surname": "CHEN", "givenNames": "EMMA LIN", "dateOfBirth": "2021-11-03", "placeOfBirth": "Seattle, Washington",
                   "sex": "F", "documentNumber": "2021-0047182", "issueDate": "2021-11-20"},
        "contents": [
            entry("Birth", "Time of birth", "4:12 PM", True), entry("Birth", "Facility", "Lakeview Medical Center", True),
            entry("Birth", "County", "Kingsley", False), entry("Birth", "Certificate number", "2021-0047182", True),
            entry("Registrar", "Local registrar", "Helen Marsh"), entry("Registrar", "Date filed", "2021-11-09"),
        ],
        "details": [
            detail("Name", "Anna Maria Eriksson", "mother", "Anna Maria Eriksson", True),
            detail("Date of birth", "1990-08-12", "mother", "Anna Maria Eriksson"),
            detail("Place of birth", "Utopia", "mother", "Anna Maria Eriksson"),
            detail("Name", "David Lee Chen", "father", "David Lee Chen", True),
            detail("Date of birth", "1988-03-05", "father", "David Lee Chen"),
            detail("Place of birth", "Utopia", "father", "David Lee Chen"),
            detail("Mother's address at birth", "412 Alder St, Apt 3B, Seattle, WA 98101"),
        ],
    },
    {
        "id": "emma-immunizations", "holder": "emma", "kind": "other", "template": "kidvax",
        "file": "Emma · Immunization record", "variants": ["clean"],
        "fields": {"surname": "CHEN", "givenNames": "EMMA LIN", "dateOfBirth": "2021-11-03", "issueDate": "2026-09-02"},
        "vaccines": [
            ("Hepatitis B", "dose 1", "2021-11-04", "HB8810", "Lakeview Medical Center"),
            ("Hepatitis B", "dose 2", "2022-01-05", "HB9021", "Rose City Pediatrics"),
            ("DTaP", "dose 1", "2022-01-05", "DT1102", "Rose City Pediatrics"),
            ("DTaP", "dose 2", "2022-03-07", "DT1188", "Rose City Pediatrics"),
            ("DTaP", "dose 3", "2022-05-09", "DT1250", "Rose City Pediatrics"),
            ("Hepatitis B", "dose 3", "2022-05-09", "HB9133", "Rose City Pediatrics"),
            ("MMR", "dose 1", "2022-11-07", "MR4410", "Rose City Pediatrics"),
            ("Varicella", "dose 1", "2022-11-07", "VR2203", "Rose City Pediatrics"),
            ("DTaP", "dose 4", "2023-02-14", "DT1391", "Rose City Pediatrics"),
            ("Influenza", "", "2025-10-12", "FL2581", "Pine Pharmacy"),
            ("MMR", "dose 2", "2026-09-02", "MR5127", "Rose City Pediatrics"),
            ("Varicella", "dose 2", "2026-09-02", "VR2390", "Rose City Pediatrics"),
        ],
        "contents_extra": [entry("Clinic", "Pediatrician", "Dr. Alicia Moreno", True)],
    },
]


def vaccine_entries(doc):
    """A vaccination record's rows as `contents` entries (label "MMR · dose 1", value "date · Lot X · place")."""
    rows = []
    for name, dose, date, lot, place in doc.get("vaccines", []):
        label = f"{name} · {dose}" if dose else name
        rows.append(entry("Vaccinations", label, f"{date} · Lot {lot} · {place}", True))
    return rows + doc.get("contents_extra", [])


for _doc in DOCUMENTS:
    if "vaccines" in _doc:
        _doc["contents"] = vaccine_entries(_doc)
    _doc.setdefault("contents", [])
    _doc.setdefault("details", [])
    _doc.setdefault("travel", [])


# ------------------------------------------------------------------------------------------------ Conflicts

# Where documents disagree, or look like they disagree, and what the right answer is and why.
CONFLICTS = [
    {"id": "current-passport", "kind": "superseded document",
     "facts": ["anna-passport-2009.documentNumber", "anna-passport-2019.documentNumber"],
     "answer": "PX7204821", "rule": "Two passports: the one valid today (latest expiry, not expired) is current; the other is history."},
    {"id": "current-address", "kind": "newer evidence",
     "facts": ["anna-dl-or-2023.address", "lease-2023-pine.address", "lease-2023-pine-termination", "lease-2026-lovejoy.address"],
     "answer": "1720 NW Lovejoy St, Apt 210, Portland, OR 97209",
     "rule": "The driver's licence (2023) and the 2023 lease (to 2027-12-31) say 88 Pine Ave, but the termination addendum ends that lease on 2026-06-30 and the 2026 lease starts 2026-07-01. Evidence dated later wins; a licence address is only as current as its issue date."},
    {"id": "lease-2023-end", "kind": "amendment",
     "facts": ["lease-2023-pine.leaseEndDate", "lease-2023-pine-termination"],
     "answer": "2026-06-30", "rule": "An addendum changes the lease it amends."},
    {"id": "anna-dob", "kind": "typo",
     "facts": ["anna-passport-2019.dateOfBirth", "anna-greencard.dateOfBirth", "anna-labs-2026.dateOfBirth"],
     "answer": "1990-08-12", "rule": "Six documents (two with machine-checked MRZ) say 1990-08-12; one lab report says 1990-08-21. Checked and majority values win; the outlier is flagged, not silently dropped."},
    {"id": "anna-surname", "kind": "name variant",
     "facts": ["anna-passport-2019.surname", "anna-insurance-card.surname"],
     "answer": "ERIKSSON", "rule": "ERIKSSON-CHEN on the insurance card is another name used, not a conflict: identity documents give the legal name; keep the variant as an alias."},
    {"id": "anna-given-names", "kind": "abbreviation",
     "facts": ["anna-passport-2019.givenNames", "anna-dl-wa-2020.givenNames", "anna-labs-2026.givenNames"],
     "answer": "ANNA MARIA", "rule": "ANNA M and ANNA are compatible shortenings of ANNA MARIA."},
    {"id": "anna-phone", "kind": "changed over time",
     "facts": ["lease-2020-alder.phone", "lease-2026-lovejoy.phone"],
     "answer": "(503) 555-0188", "rule": "Contact details change: the most recent document wins; older numbers are history."},
    {"id": "anna-licence", "kind": "superseded document",
     "facts": ["anna-dl-wa-2020.documentNumber", "anna-dl-or-2023.documentNumber"],
     "answer": "7812345", "rule": "The Washington licence expired 2026-08-12 and the Oregon one was issued later: Oregon is current."},
    {"id": "anna-tetanus", "kind": "events, not a conflict",
     "facts": ["anna-vaccination-card", "anna-i693"],
     "answer": "2020-02-20", "rule": "Doses on different documents are separate events; the latest tetanus-containing dose (Tdap on the I-693) is the last shot."},
    {"id": "anna-status", "kind": "status history",
     "facts": ["anna-ead-2020.uscisCategory", "anna-greencard.uscisCategory", "anna-i94.classOfAdmission"],
     "answer": "Permanent resident (E21) since 2021-03-02",
     "rule": "H1B (I-94), then C09 (EAD, pending adjustment), then E21 green card: the latest status is current; earlier ones are history."},
]


# ------------------------------------------------------------------------------------------------ Questions

def q(question, answer, kind, person="anna", sources=(), sensitive=False, accept=None):
    return {"question": question, "answer": answer, "kind": kind, "person": person, "sources": list(sources),
            "sensitive": sensitive, "accept": accept or [answer]}


QUESTIONS = [
    # Identity
    q("When does my passport expire?", "2029-03-14", "lookup+current", sources=["anna-passport-2019"]),
    q("What's my passport number?", "PX7204821", "lookup+current", sources=["anna-passport-2019"], sensitive=True),
    q("What was my old passport number?", "PX1938457", "history", sources=["anna-passport-2009"], sensitive=True),
    q("Is my passport still valid?", "Yes, until 2029-03-14", "derived", sources=["anna-passport-2019"], accept=["yes", "2029-03-14"]),
    q("What's my date of birth?", "1990-08-12", "conflict", sources=["anna-passport-2019"]),
    q("Where was I born?", "Lumen City, Utopia", "lookup", accept=["Lumen City"]),
    q("What's my nationality?", "Utopian", "lookup"),
    q("What's my full legal name?", "Anna Maria Eriksson", "conflict"),
    q("What other names have I used?", "Anna Eriksson-Chen", "conflict", accept=["Eriksson-Chen"]),
    q("How tall am I?", "5'6\" (168 cm)", "lookup", accept=["5'-06\"", "5'6", "168"]),
    q("What colour are my eyes?", "Brown", "lookup", accept=["brown", "BRN"]),
    q("What's my driver's licence number?", "7812345", "lookup+current", sources=["anna-dl-or-2023"], sensitive=True),
    q("When does my driver's licence expire?", "2031-08-12", "lookup+current", sources=["anna-dl-or-2023"]),
    q("What's my Social Security number?", "987-65-4321", "lookup", sources=["anna-ssn-card"], sensitive=True),
    # Immigration
    q("What's my A-number?", "204815962", "lookup", sources=["anna-greencard"], sensitive=True, accept=["204815962", "204-815-962"]),
    q("When does my green card expire?", "2031-03-01", "lookup", sources=["anna-greencard"]),
    q("When did I become a permanent resident?", "2021-03-02", "lookup", sources=["anna-greencard"]),
    q("What's my green card category?", "E21", "lookup", sources=["anna-greencard"]),
    q("What's my immigration status?", "Permanent resident (E21) since 2021-03-02", "conflict", accept=["permanent resident", "E21"]),
    q("When was my I-485 approved?", "2021-03-05", "lookup", sources=["anna-i797-i485"]),
    q("What's my I-485 receipt number?", "MSC2190312345", "lookup", sources=["anna-i797-i485"], sensitive=True),
    q("What's my priority date?", "2019-11-04", "lookup-contents", sources=["anna-i797-i485"]),
    q("What was my EAD category?", "C09", "history", sources=["anna-ead-2020"]),
    q("When did my EAD card expire?", "2021-04-30", "history", sources=["anna-ead-2020"]),
    q("What's my I-94 number?", "93847561020", "lookup", sources=["anna-i94"], sensitive=True),
    q("When did I last enter the US?", "2025-03-22", "aggregate", sources=["anna-i94"]),
    q("How many days was I outside the US in 2024?", "16", "aggregate", sources=["anna-i94"], accept=["16", "15", "17"]),
    q("How many trips abroad have I taken since 2021?", "4", "aggregate", sources=["anna-i94"]),
    # Housing
    q("What's my current address?", "1720 NW Lovejoy St, Apt 210, Portland, OR 97209", "conflict", accept=["1720 NW Lovejoy"]),
    q("Where did I live in 2021?", "412 Alder St, Apt 3B, Seattle, WA 98101", "temporal", accept=["412 Alder"]),
    q("Where did we live in 2024?", "88 Pine Ave, Portland, OR 97205", "temporal", accept=["88 Pine"]),
    q("When does my lease end?", "2027-06-30", "lookup+current", sources=["lease-2026-lovejoy"]),
    q("How much is my rent?", "$2,950.00", "lookup-contents", sources=["lease-2026-lovejoy"], accept=["2,950", "2950"]),
    q("What was my rent at Pine Ave?", "$2,480.00", "lookup-contents", sources=["lease-2023-pine"], accept=["2,480", "2480"]),
    q("Who is my landlord?", "Lovejoy Lofts LLC", "lookup-contents", sources=["lease-2026-lovejoy"], accept=["Lovejoy Lofts"]),
    q("When did we move out of Pine Ave?", "2026-06-30", "conflict", sources=["lease-2023-pine-termination"]),
    q("What's my parking space?", "G-07", "lookup-contents", sources=["lease-2026-lovejoy"]),
    q("How much was my security deposit at Lovejoy?", "$2,950.00", "lookup-contents", sources=["lease-2026-lovejoy"], accept=["2,950", "2950"]),
    q("What's my phone number?", "(503) 555-0188", "conflict", accept=["555-0188"]),
    q("What's my email?", "anna.eriksson@example.com", "lookup"),
    # Health
    q("When was my last tetanus shot?", "2020-02-20", "events", sources=["anna-i693"]),
    q("When did I get my COVID booster?", "2023-10-02", "lookup-contents", sources=["anna-vaccination-card"]),
    q("When did I last get a flu shot?", "2025-10-12", "events", sources=["anna-vaccination-card"]),
    q("How many hepatitis B doses have I had?", "3", "aggregate", sources=["anna-vaccination-card"]),
    q("Was my TB test negative?", "Yes, QuantiFERON negative on 2020-02-20", "lookup-contents", sources=["anna-i693"], accept=["negative"]),
    q("Who did my immigration medical exam?", "Dr. Priya Raman", "lookup-contents", sources=["anna-i693"], accept=["Raman"]),
    q("What was my vitamin D level?", "32 ng/mL", "lookup-contents", sources=["anna-labs-2026"], accept=["32"]),
    q("What's my A1C?", "5.4%", "lookup-contents", sources=["anna-labs-2026"], accept=["5.4"]),
    q("Was my LDL high?", "Yes, 104 mg/dL (reference under 100)", "lookup-contents", sources=["anna-labs-2026"], accept=["104"]),
    q("What's my health insurance member ID?", "ZXA884512703", "lookup-contents", sources=["anna-insurance-card"], sensitive=True),
    q("What's my insurance group number?", "0047731", "lookup-contents", sources=["anna-insurance-card"]),
    q("What's my specialist copay?", "$50", "lookup-contents", sources=["anna-insurance-card"], accept=["50"]),
    # Money and family
    q("How much did I earn in 2025?", "$148,250.00", "lookup-contents", sources=["anna-w2-2025"], accept=["148,250", "148250"]),
    q("How much federal tax was withheld in 2025?", "$27,410.55", "lookup-contents", sources=["anna-w2-2025"], accept=["27,410.55"]),
    q("Who is my employer?", "Brightwater Analytics LLC", "lookup", accept=["Brightwater"]),
    q("What's my employer's EIN?", "98-7654321", "lookup-contents", sources=["anna-w2-2025"]),
    q("When did I get married?", "2018-06-23", "lookup-contents", sources=["marriage-certificate"]),
    q("What's my mother's maiden name?", "Holm", "lookup-family", sources=["marriage-certificate"]),
    q("What's my father's name?", "Lars Eriksson", "lookup-family", sources=["marriage-certificate"]),
    q("What's my marriage certificate number?", "2018-MC-031557", "lookup-contents", sources=["marriage-certificate"]),
    # Spouse and child
    q("When does David's passport expire?", "2027-06-30", "lookup", person="david", sources=["david-passport-2017"]),
    q("What's David's passport number?", "PY5512093", "lookup", person="david", sources=["david-passport-2017"], sensitive=True),
    q("What's my husband's A-number?", "204815977", "lookup", person="david", sources=["david-greencard"], sensitive=True, accept=["204815977", "204-815-977"]),
    q("When is David's birthday?", "1988-03-05", "lookup", person="david"),
    q("When was Emma born?", "2021-11-03", "lookup", person="emma", sources=["emma-birth-certificate"]),
    q("What time was Emma born?", "4:12 PM", "lookup-contents", person="emma", sources=["emma-birth-certificate"]),
    q("Which hospital was Emma born in?", "Lakeview Medical Center", "lookup-contents", person="emma", sources=["emma-birth-certificate"]),
    q("What's Emma's birth certificate number?", "2021-0047182", "lookup", person="emma", sources=["emma-birth-certificate"], sensitive=True),
    q("When was Emma's last DTaP shot?", "2023-02-14", "events", person="emma", sources=["emma-immunizations"]),
    q("How many DTaP doses has Emma had?", "4", "aggregate", person="emma", sources=["emma-immunizations"]),
    q("Has Emma had her second MMR?", "Yes, on 2026-09-02", "events", person="emma", sources=["emma-immunizations"], accept=["2026-09-02"]),
    q("Who is Emma's pediatrician?", "Dr. Alicia Moreno", "lookup-contents", person="emma", sources=["emma-immunizations"], accept=["Moreno"]),
    # Across the household
    q("Which of our documents expire before the end of 2027?", "David's passport (2027-06-30) and the Lovejoy lease (2027-06-30)", "aggregate",
      person="household", accept=["David", "passport", "2027-06-30"]),
    q("Whose documents expire next?", "David's passport, 2027-06-30", "aggregate", person="household", accept=["David", "2027-06-30"]),
]
