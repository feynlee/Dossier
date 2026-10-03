# Dossier

A private iOS 27 vault that reads your identity, immigration and housing documents from an iCloud Drive
folder, extracts the facts with Apple's Private Cloud Compute, verifies them, and stores them encrypted on
the device. It answers questions through Siri, draws your history on a timeline and map, and fills PDF forms.
Design system and architecture: https://claude.ai/artifact/5s2cvvfakSxCnfqp95FNkW

## Features

| Tab or surface | What it does |
| --- | --- |
| Vault | Personal information, what needs review, and the documents you added, with reading status |
| Adding documents | + opens the Files picker: open any folder (iCloud Drive included) and select several files. Only added files are read; a changed file is read again and its result replaced |
| Scanning | + › Scan Documents: the page is outlined live and taken automatically once steady (Auto, the default, set in Settings) or with the shutter (Manual). Keep taking pages; review to retake, crop, rotate or delete any page. Saved as one PDF to a folder in iCloud Drive (the default from Settings, else the last folder used, changeable for each scan), then read like any added file |
| Editing a file | On a document's page (••• or Source): Edit Pages shows the pages in a grid to select, drag into a new order, rotate, delete, or insert pages from a scan; a PDF is saved in place, a photo becomes a new PDF in iCloud Drive (the photo isn't changed). Replace File swaps in a new scan (written over the PDF after confirming) or another file you choose. Pages that show a number need Face ID first. The document is read again afterwards |
| Personal information | Name, birth date, sex, place of birth, nationality, A-Number, current passport and licence numbers, and current address, reconciled across documents. Agreeing values are accepted automatically; any value can be edited |
| Checking fields | Each document's page. Fields Dossier wasn't sure about show Edit and Looks Right in the row; two readings that differ show both to pick from. Any field can be edited (a date picker for dates, with the line it was read from). Confirming a name, birth date, sex, place of birth, nationality or A-Number confirms the same reading on your other documents and on documents you add later. Documents that disagree are resolved in Personal information |
| Document detail | Zoomable preview of the file above its fields. One Face ID on the page shows the file and every number, in place, until you leave the page or the app; tap a field to zoom to where it was read and to edit or copy it |
| Timeline › List | Year scrubber, homes, trips, statuses and address gaps (with "Add address") for the selected year |
| Timeline › Map | Homes as numbered pins joined by moves; trips with a destination as arcs; the scrubber moves the camera |
| Timeline › Overview | Swimlanes for homes, status, documents and trips, days abroad per year, and an "on this date" crosshair |
| Forms | Choose a fillable PDF, match its fields to your facts, fill with Face ID for numbers, save a copy |
| Siri and Shortcuts | "What's my passport number in Dossier", expiry dates, "Where did I live", days abroad |
| App lock | Face ID (passcode fallback) on launch, when the iPhone locks, and after 1 minute in the background (Immediately, 1, 5 or 15 minutes in Settings). The lock covers open sheets too |
| Managing documents | All in the Vault. One document: swipe, touch and hold, or the ••• menu on its page (Read Again, Remove from Vault). Several: ••• › Select, then Read Again or Remove in the bottom bar. All: ••• › Read All Again or Remove All Documents (documents, edits, timeline and keys), which leaves the empty Vault ready to add files again. Removing never deletes the file itself |
| Settings | Preferences only: Private Cloud Compute on/off, scanning (auto-capture, default scan folder), app lock and its timeout |

## Layout

| Folder | What |
| --- | --- |
| `Dossier/App` | Entry point, `VaultStore` (shared SwiftData container), tabs, `AppLock` (whole-app lock and app-switcher cover) |
| `Dossier/DesignSystem` | Indigo tint tokens, `BadgedTile`, `MaskedValueView` |
| `Dossier/Models` | SwiftData `SourceDocument`, `Fact`, `TravelEvent`; `FactKey`, `DocumentKind` |
| `Dossier/Security` | `VaultKeys` (Keychain AES key + Secure Enclave key), `Sealer`, Face ID, `VaultReader` |
| `Dossier/Scan` | Camera and live page detection (`ScanCamera`, adapted from BillSplit), `ScannedPage` (perspective-corrected pages, PDF), `ScanSession` (auto-capture, retake), `ScanFolders` (iCloud Drive folders), `DocumentScanner` screens, `PageEditor` (edit a file's pages) |
| `Dossier/Ingestion` | `FileAccess` (a bookmark per added file), folder browsing for the checklist, page rendering, Vision text (with line positions) and PDF417 |
| `Dossier/Parsing` | `MRZParser` (ICAO 9303 TD1/TD3 with check digits), `AAMVAParser`, `SimpleDate` |
| `Dossier/Extraction` | `@Generable` schema, `DocumentExtractor` (PCC with on-device fallback), `Verifier` |
| `Dossier/Import` | `ImportCoordinator`: a queue of added files → download → read → extract → verify → seal, one result per file |
| `Dossier/Profile` | `Reconciler` (pure matching rules), `Profile` (compiled personal information and your edits), `SharedConfirmation` (a confirmation reaches every document with the same reading) |
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
- The whole app locks behind Face ID. Turning the lock off or lengthening the timeout needs Face ID, so
  someone holding your unlocked phone can't weaken it. Revealing a number still asks again.
- Siri says only the last four characters of a number. Intents need the device unlocked.
- MapKit geocoding receives address strings only; coordinates stay in memory.

## Requirements

- Xcode 27, iOS 27.
- The `com.apple.developer.private-cloud-compute` entitlement (Small Business Program).

## Try it in the Simulator

Copy `SampleDocuments/*` into the Files app (On My iPhone), choose that folder on first launch, and enroll
Face ID from the Simulator's Features menu to reveal masked numbers. Use `Sample application form.pdf` in
the Forms tab.
