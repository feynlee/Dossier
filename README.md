# Dossier

A private iOS 27 vault that reads your identity, immigration and housing documents from an iCloud Drive
folder, extracts the facts with Apple's Private Cloud Compute, verifies them, and stores them encrypted on
the device. Design system and architecture: https://claude.ai/artifact/5s2cvvfakSxCnfqp95FNkW

## Layout

| Folder | What |
| --- | --- |
| `Dossier/App` | Entry point, tabs, app-switcher privacy cover |
| `Dossier/DesignSystem` | Indigo tint tokens, `BadgedTile`, `MaskedValueView` |
| `Dossier/Models` | SwiftData `SourceDocument` and `Fact`, `FactKey`, `DocumentKind` |
| `Dossier/Security` | `VaultKeys` (Keychain AES key + Secure Enclave key), `Sealer`, Face ID, `VaultReader` |
| `Dossier/Ingestion` | Folder bookmark and listing, page rendering, Vision text and PDF417 reading |
| `Dossier/Parsing` | `MRZParser` (ICAO 9303 TD1/TD3 with check digits), `AAMVAParser`, `SimpleDate` |
| `Dossier/Extraction` | `@Generable` schema, `DocumentExtractor` (PCC with on-device fallback), `Verifier` |
| `Dossier/Import` | `ImportCoordinator`: list → read → extract → verify → seal → save |
| `Dossier/Features` | Onboarding, Vault, document detail, Review, Settings |
| `SampleDocuments` | A specimen passport and lease with made-up data, for testing imports |

## Pipeline

1. The folder is remembered as a bookmark; files are read in place with file coordination, never copied.
2. Pages are rendered (PDFKit/ImageIO) and read locally with Vision (text + PDF417).
3. `PrivateCloudComputeLanguageModel` fills a `DocumentReading` schema, with page images attached when the
   model reports the `.vision` capability. Network, quota or availability errors fall back to the on-device model.
4. `Verifier` cross-checks against the MRZ check digits and the licence barcode. Matches are verified
   automatically; everything else goes to the review queue.
5. Values are sealed: AES-GCM under a device-only Keychain key, or, for document numbers, encrypted to a
   Secure Enclave key that needs Face ID to decrypt.

## Requirements

- Xcode 27, iOS 27.
- The `com.apple.developer.private-cloud-compute` entitlement (Small Business Program).

## Try it in the Simulator

Copy `SampleDocuments/*` into the Files app (On My iPhone), choose that folder on first launch, and enroll
Face ID from the Simulator's Features menu to reveal masked numbers.
