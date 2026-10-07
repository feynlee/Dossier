import AuthenticationServices
import SwiftUI

/// Dossier in the system's AutoFill menu: touch and hold a text field in any app, choose AutoFill › Dossier,
/// unlock, and pick a value to insert.
final class CredentialProviderViewController: ASCredentialProviderViewController {
    override func prepareInterfaceForUserChoosingTextToInsert() {
        let picker = AutoFillPicker(
            onPick: { [weak self] text in self?.extensionContext.completeRequest(withTextToInsert: text) },
            onCancel: { [weak self] in
                self?.extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: ASExtensionError.userCanceled.rawValue))
            }
        )
        let host = UIHostingController(rootView: picker)
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }
}
