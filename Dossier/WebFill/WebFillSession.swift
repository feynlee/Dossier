import Foundation
import LocalAuthentication
import Observation
import WebKit

/// A web page you're filling in. Dossier reads its fields, matches them to your values, and writes the ones
/// you confirm. It never submits anything: the site's own buttons stay yours to press.
@MainActor
@Observable
final class WebFillSession: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView

    private(set) var url: URL?
    private(set) var title = ""
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isLoading = false
    private(set) var progress = 0.0
    /// Fields on the page that Dossier can fill, by the quick (rules-only) match after each load.
    private(set) var fillableCount = 0
    private(set) var loadError: String?

    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    /// Dossier's scripts run here, out of the page's reach.
    private let world = WKContentWorld.world(name: "Dossier")

    /// The site, for remembering matches: "ceac.state.gov".
    var site: String { url?.host()?.lowercased() ?? "" }

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        observations = [
            webView.observe(\.canGoBack) { [weak self] view, _ in MainActor.assumeIsolated { self?.canGoBack = view.canGoBack } },
            webView.observe(\.canGoForward) { [weak self] view, _ in MainActor.assumeIsolated { self?.canGoForward = view.canGoForward } },
            webView.observe(\.estimatedProgress) { [weak self] view, _ in MainActor.assumeIsolated { self?.progress = view.estimatedProgress } },
            webView.observe(\.url) { [weak self] view, _ in MainActor.assumeIsolated { self?.url = view.url } },
            webView.observe(\.title) { [weak self] view, _ in MainActor.assumeIsolated { self?.title = view.title ?? "" } },
        ]
    }

    /// Opens an address, adding https:// when it's missing.
    func open(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let address = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: address) else { return }
        loadError = nil
        webView.load(URLRequest(url: url))
        WebFillHistory.record(url)
    }

    // MARK: Reading and filling

    /// The page's fields, described for the matcher.
    func scan() async -> [FieldDescriptor] {
        guard let result = try? await webView.callAsyncJavaScript(WebFillScript.scan, contentWorld: world) as? [[String: Any]] else { return [] }
        return result.compactMap { item in
            guard let token = item["token"] as? String else { return nil }
            let name = item["name"] as? String ?? "", id = item["idAttr"] as? String ?? "", label = item["label"] as? String ?? ""
            return FieldDescriptor(
                id: token,
                memoryKey: name.isEmpty ? (id.isEmpty ? "label:\(label.lowercased())" : "id:\(id)") : "name:\(name)",
                label: label.isEmpty ? FormFieldMatcher.words(name.isEmpty ? id : name) : label,
                context: item["section"] as? String ?? "",
                name: [name, id].filter { !$0.isEmpty }.joined(separator: " "),
                autocomplete: (item["autocomplete"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                inputType: item["type"] as? String ?? "text",
                options: item["options"] as? [String] ?? [],
                placeholder: (item["placeholder"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                maxLength: (item["maxLength"] as? Int).flatMap { $0 > 0 ? $0 : nil },
                currentValue: item["value"] as? String ?? ""
            )
        }
    }

    /// Writes values into fields: field token → ways to write the value. Returns which were filled.
    func fill(_ values: [String: [String]]) async -> [String: Bool] {
        let items = values.map { ["token": $0.key, "candidates": $0.value] }
        let result = try? await webView.callAsyncJavaScript(WebFillScript.fill, arguments: ["items": items], contentWorld: world)
        return (result as? [String: Bool]) ?? [:]
    }

    /// Attaches a file from the vault to an upload field.
    func attach(_ data: Data, name: String, type: String, to token: String) async -> Bool {
        let arguments: [String: Any] = ["token": token, "name": name, "type": type, "base64": data.base64EncodedString()]
        return (try? await webView.callAsyncJavaScript(WebFillScript.attach, arguments: arguments, contentWorld: world) as? Bool) ?? false
    }

    /// A quick count after each page loads, so the Fill button can say how much it can do.
    func countFillable(catalog: FormCatalog) async {
        let fields = await scan()
        let slots = Set(catalog.slots.map(\.slot))
        let memory = FormMemory.matches(for: site)
        // Only empty fields count: once a page is filled, the button says so.
        fillableCount = fields.filter { $0.inputType != "file" && $0.currentValue.isEmpty && FormMatcher.match($0, slots: slots, memory: memory) != nil }.count
    }

    /// The page as a PDF, such as a confirmation, to keep in the vault.
    func pagePDF() async -> Data? {
        try? await webView.pdf()
    }

    // MARK: Navigation

    var onPageLoaded: (() -> Void)?

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        fillableCount = 0
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        onPageLoaded?()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        if (error as NSError).code != NSURLErrorCancelled { loadError = error.localizedDescription }
    }

    /// Links that open a new window open here instead.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    /// Clears sign-ins and cookies for every site opened in Dossier.
    static func clearWebsiteData() async {
        let store = WKWebsiteDataStore.default()
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }
}

/// Sites you've filled, most recent first, for the start page. Only addresses are kept.
nonisolated enum WebFillHistory {
    private static let key = "webFillRecentSites"

    static var recent: [URL] {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).compactMap(URL.init(string:))
    }

    static func record(_ url: URL) {
        guard let host = url.host(), let origin = URL(string: "https://\(host)") else { return }
        var list = UserDefaults.standard.stringArray(forKey: key) ?? []
        list.removeAll { $0 == origin.absoluteString }
        list.insert(origin.absoluteString, at: 0)
        UserDefaults.standard.set(Array(list.prefix(8)), forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
