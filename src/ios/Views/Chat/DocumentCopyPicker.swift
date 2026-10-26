import SwiftUI
import UniformTypeIdentifiers

/// [T-sideload-fileimport] UIKit document picker in asCopy mode.
///
/// SwiftUI's `.fileImporter` (and any open-in-place picker) requires a
/// FileProvider security-scoped grant for the picked URL. On resigned /
/// sideloaded builds iOS silently refuses that grant: the picker opens, the
/// user picks a file, "Open" does nothing, no error is delivered. Empo and
/// ios-local-llm hit the same wall and independently converged on the same
/// fix — present `UIDocumentPickerViewController(forOpeningContentTypes:
/// asCopy: true)`, which copies the file into the app's tmp and hands back a
/// plain file: URL, bypassing the security-scope dance entirely.
///
/// Contract: URLs handed to `onPick` point into tmp and must be consumed
/// (copied out) promptly — callers here funnel into
/// `AIChatViewModel.addFileAttachment` which does exactly that.
struct DocumentCopyPicker: UIViewControllerRepresentable {
    let contentTypes: [UTType]
    let allowsMultipleSelection: Bool
    let onPick: ([URL]) -> Void
    var onDone: () -> Void = {}

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
        picker.allowsMultipleSelection = allowsMultipleSelection
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onDone: onDone) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        let onDone: () -> Void
        init(onPick: @escaping ([URL]) -> Void, onDone: @escaping () -> Void) {
            self.onPick = onPick
            self.onDone = onDone
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if !urls.isEmpty { onPick(urls) }
            onDone()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onDone()
        }
    }
}
