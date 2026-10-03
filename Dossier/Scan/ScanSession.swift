import Foundation
import Observation
import UIKit

/// The pages of one scan and the camera that takes them, like the scanner in Notes: the page is found and
/// outlined live, taken automatically once it's held steady (or with the shutter), and pages pile up until
/// you save. Any page can be retaken, re-cropped, turned or deleted.
@Observable
final class ScanSession {
    let camera = ScanCamera()

    private(set) var outline: PageOutline?
    private(set) var pages: [ScannedPage] = []
    /// Takes the photo by itself once the page is steady. Starts from the setting; the switch in the
    /// scanner changes it for this scan only.
    var autoCapture: Bool
    var torchOn = false { didSet { camera.setTorch(torchOn) } }
    private(set) var isCapturing = false
    private(set) var cameraError: String?
    /// The page the next photo replaces, when retaking.
    var retaking: Int?
    /// Changes on every capture, for the flash and haptic.
    private(set) var captureCount = 0

    // Auto-capture: the last few outlines, and whether the page in view was already taken.
    @ObservationIgnored private var recent: [PageOutline] = []
    @ObservationIgnored private var lastCaptured: PageOutline?

    /// How many analyzed frames (about a second) the page must hold still for, and how still.
    static let steadyFrames = 7
    static let steadyTolerance: CGFloat = 0.02
    /// How far the page must move, or for how long it must leave the frame, before the next auto-capture:
    /// so one page isn't taken twice while you reach for the next.
    static let newPageDistance: CGFloat = 0.15

    init(autoCapture: Bool) {
        self.autoCapture = autoCapture
    }

    func start() async {
        camera.analyzer.onChange = { [weak self] outline in
            guard let self else { return }
            Task { @MainActor in self.update(outline) }
        }
        do {
            try await camera.start()
            cameraError = nil
        } catch {
            cameraError = error.localizedDescription
        }
    }

    func stop() {
        torchOn = false
        camera.stop()
    }

    var status: String {
        if let cameraError { return cameraError }
        if isCapturing { return "Taking photo…" }
        guard let outline else { return autoCapture ? "Looking for a document" : "Point at a document and tap the shutter" }
        if outline.isTooFar { return "Move closer" }
        if autoCapture, lastCaptured != nil, outline.distance(to: lastCaptured!) < Self.newPageDistance { return "Ready for the next page" }
        return autoCapture ? "Hold steady" : "Tap the shutter"
    }

    // MARK: Capturing

    private func update(_ outline: PageOutline?) {
        self.outline = outline
        guard let outline else {
            // The page left the frame: the next one in view is a new page.
            recent = []
            lastCaptured = nil
            return
        }
        recent.append(outline)
        if recent.count > Self.steadyFrames { recent.removeFirst(recent.count - Self.steadyFrames) }
        if let lastCaptured, outline.distance(to: lastCaptured) >= Self.newPageDistance { self.lastCaptured = nil }

        guard autoCapture, !isCapturing, lastCaptured == nil, !outline.isTooFar, recent.count == Self.steadyFrames,
              recent.allSatisfy({ $0.distance(to: outline) < Self.steadyTolerance }) else { return }
        Task { await capture() }
    }

    func capture() async {
        guard !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }
        let seen = outline
        do {
            let photo = try await camera.capturePhoto()
            captureCount += 1
            lastCaptured = seen
            recent = []
            guard let page = await Self.process(photo, fallback: seen) else { return }
            if let retaking, pages.indices.contains(retaking) {
                pages[retaking] = page
                self.retaking = nil
            } else {
                pages.append(page)
            }
        } catch {
            cameraError = error.localizedDescription
        }
    }

    @concurrent
    private static func process(_ photo: UIImage, fallback: PageOutline?) async -> ScannedPage? {
        ScannedPage.make(from: photo, fallback: fallback)
    }

    // MARK: Editing pages

    func delete(at index: Int) {
        guard pages.indices.contains(index) else { return }
        pages.remove(at: index)
        if retaking == index { retaking = nil }
    }

    func turn(at index: Int) {
        guard pages.indices.contains(index) else { return }
        pages[index].turns = (pages[index].turns + 1) % 4
        pages[index].rerender()
    }

    func setOutline(_ outline: PageOutline, at index: Int) {
        guard pages.indices.contains(index) else { return }
        pages[index].outline = outline
        pages[index].rerender()
    }
}

// MARK: Where scans are saved

/// Scans are saved as PDFs to a folder in iCloud Drive, then added to the vault like any other file. The
/// folder is the default from Settings when there is one, otherwise the folder you saved to last; you can
/// change it for each scan.
nonisolated enum ScanFolders {
    static let autoCaptureKey = "scanAutoCapture"
    static let defaultFolderKey = "scanDefaultFolder"
    static let lastFolderKey = "scanLastFolder"

    enum SaveError: LocalizedError {
        case notInICloud, noFolder, couldNotWrite

        var errorDescription: String? {
            switch self {
            case .notInICloud: "Choose a folder in iCloud Drive. Scans are kept in iCloud Drive, like the other files Dossier reads."
            case .noFolder: "Choose a folder in iCloud Drive to save the scan to."
            case .couldNotWrite: "The scan couldn’t be saved to that folder."
            }
        }
    }

    static var store: UserDefaults { .standard }

    static var defaultFolder: URL? { folder(forKey: defaultFolderKey) }
    static var lastFolder: URL? { folder(forKey: lastFolderKey) }
    /// Where a new scan goes unless you choose another folder.
    static var preferredFolder: URL? { defaultFolder ?? lastFolder }

    static func setDefaultFolder(_ url: URL?) throws {
        guard let url else {
            store.removeObject(forKey: defaultFolderKey)
            return
        }
        guard isInICloud(url) else { throw SaveError.notInICloud }
        store.set(try FileAccess.bookmark(for: url), forKey: defaultFolderKey)
    }

    private static func folder(forKey key: String) -> URL? {
        guard let data = store.data(forKey: key), let resolved = FileAccess.resolve(data) else { return nil }
        if let refreshed = resolved.refreshed { store.set(refreshed, forKey: key) }
        // A folder that was deleted, or moved out of iCloud Drive, can't be used.
        guard FileAccess.exists(resolved.url), isInICloud(resolved.url) else { return nil }
        return resolved.url
    }

    /// Whether a folder is in iCloud Drive (not On My iPhone or another provider).
    static func isInICloud(_ url: URL) -> Bool {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        if (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true { return true }
        return url.standardizedFileURL.path.contains("/Mobile Documents/")
    }

    /// "Scan 2026-10-03 14.32", sortable and unique enough to be a good default name.
    static func suggestedName(on date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "Scan \(formatter.string(from: date))"
    }

    /// A file name that's safe and not already taken in `folder`: "Passport", then "Passport 2"…
    static func fileName(for name: String, existing: Set<String>, extension ext: String = "pdf") -> String {
        let cleaned = name
            .components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>").union(.newlines)).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let base = cleaned.isEmpty ? suggestedName() : cleaned
        var candidate = "\(base).\(ext)", number = 2
        while existing.contains(candidate.lowercased()) {
            candidate = "\(base) \(number).\(ext)"
            number += 1
        }
        return candidate
    }

    /// Writes a file (a PDF unless another extension is given) into the folder and remembers the folder as
    /// the last one used. Returns the file.
    static func save(_ pdf: Data, named name: String, extension ext: String = "pdf", in folder: URL) throws -> URL {
        guard isInICloud(folder) else { throw SaveError.notInICloud }
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        let existing = Set(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).map { $0.lowercased() })
        let file = folder.appending(path: fileName(for: name, existing: existing, extension: ext))
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: file, options: .forReplacing, error: &coordinationError) { url in
            do { try pdf.write(to: url, options: [.atomic, .completeFileProtection]) } catch { writeError = error }
        }
        if coordinationError != nil || writeError != nil { throw SaveError.couldNotWrite }
        if let bookmark = try? FileAccess.bookmark(for: folder) { store.set(bookmark, forKey: lastFolderKey) }
        return file
    }
}
