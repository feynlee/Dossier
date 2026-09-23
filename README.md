# Dossier

A private iOS 27 vault that reads your identity, immigration and housing documents from an iCloud Drive
folder, extracts the facts with Apple's Private Cloud Compute, verifies them, and stores them encrypted on
the device. It answers questions through Siri, draws your history on a timeline and map, and fills PDF forms.
Design system and architecture: https://claude.ai/artifact/5s2cvvfakSxCnfqp95FNkW

## Features

| Tab or surface | What it does |
| --- | --- |
| Vault | Documents with badged icon tiles, search, and the review queue with the source line cropped from the page |
| Document detail | Facts, sensitive numbers masked until Face ID, copy for 60 s, "Show where this was read" |
| Timeline › List | Year scrubber, homes, trips, statuses and address gaps (with "Add address") for the selected year |
| Timeline › Map | Homes as numbered pins joined by moves; trips with a destination as arcs; the scrubber moves the camera |
| Timeline › Overview | Swimlanes for homes, status, documents and trips, days abroad per year, and an "on this date" crosshair |
| Forms | Choose a fillable PDF, match its fields to your facts, fill with Face ID for numbers, save a copy |
| Siri and Shortcuts | "What's my passport number in Dossier", expiry dates, "Where did I live", days abroad |
| Settings | Private Cloud Compute on/off, folder, re-read everything, delete all extracted data |

## Layout

| Folder | What |
| --- | --- |
| `Dossier/App` | Entry point, `VaultStore` (shared SwiftData container), tabs, app-switcher privacy cover |
| `Dossier/DesignSystem` | Indigo tint tokens, `BadgedTile`, `MaskedValueView` |
| `Dossier/Models` | SwiftData `SourceDocument`, `Fact`, `TravelEvent`; `FactKey`, `DocumentKind` |
| `Dossier/Security` | `VaultKeys` (Keychain AES key + Secure Enclave key), `Sealer`, Face ID, `VaultReader` |
| `Dossier/Ingestion` | Folder bookmark and listing, page rendering, Vision text (with line positions) and PDF417 |
| `Dossier/Parsing` | `MRZParser` (ICAO 9303 TD1/TD3 with check digits), `AAMVAParser`, `SimpleDate` |
| `Dossier/Extraction` | `@Generable` schema, `DocumentExtractor` (PCC with on-device fallback), `Verifier` |
| `Dossier/Import` | `ImportCoordinator`: list → read → extract → verify → seal → save |
| `Dossier/Timeline` | `LifeTimeline` (pure interval logic), `TimelineLoader`, `Geocoder` |
| `Dossier/Forms` | `FormFieldMatcher` rules, `AddressParts`, `FormFiller` (PDFKit), `FormFieldAssistant` (labels only to the model), `FactBook` |
| `Dossier/Intents` | App Intents, entities and App Shortcuts |
| `Dossier/Features` | SwiftUI screens |
| `SampleDocuments` | Specimen passport, two leases, an I-94 history and a fillable form, all made up |
| `Tools/make_assets.py` | Regenerates the app icon and the sample documents |

## Privacy decisions

- Source files are read in place and never copied. Source crops are re-rendered from the file on demand.
- Every value is sealed. Document, A-, receipt and I-94 numbers are encrypted to a Secure Enclave key that
  needs Face ID; everything else uses a device-only Keychain AES key. Only non-birth dates are stored in the
  clear, for expiry badges.
- Private Cloud Compute sees one document per request. Form matching sends only field labels.
- Siri says only the last four characters of a number. Intents need the device unlocked.
- MapKit geocoding receives address strings only; coordinates stay in memory.

## Requirements

- Xcode 27, iOS 27.
- The `com.apple.developer.private-cloud-compute` entitlement (Small Business Program).

## Try it in the Simulator

Copy `SampleDocuments/*` into the Files app (On My iPhone), choose that folder on first launch, and enroll
Face ID from the Simulator's Features menu to reveal masked numbers. Use `Sample application form.pdf` in
the Forms tab.
