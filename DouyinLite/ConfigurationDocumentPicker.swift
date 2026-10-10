import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Import a local copy rather than opening a file-provider URL in place.
@MainActor
struct ConfigurationDocumentPicker: UIViewControllerRepresentable {
    let onSelected: (String, @escaping () -> Void) -> Void
    let onResult: (Result<String, Error>) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // `.item` deliberately avoids extension/type filtering by third-party providers.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let parent: ConfigurationDocumentPicker
        private var receivedSelection = false
        private var readTask: Task<Void, Never>?

        init(parent: ConfigurationDocumentPicker) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard !receivedSelection, let url = urls.first else { return }
            receivedSelection = true
            let accessing = url.startAccessingSecurityScopedResource()
            // The delegate keeps the access grant alive until the copy has been read.
            readTask = Task { @MainActor in
                defer {
                    if accessing { url.stopAccessingSecurityScopedResource() }
                    self.removeImportedCopy(url)
                    self.readTask = nil
                }
                do {
                    let key = try await ConfigurationFileReader.readKey(from: url)
                    try Task.checkCancellation()
                    self.parent.onResult(.success(key))
                } catch { self.parent.onResult(.failure(error)) }
            }
            parent.onSelected(url.lastPathComponent, { [weak self] in self?.readTask?.cancel() })
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            guard !receivedSelection else { return }
            parent.onCancel()
        }

        private func removeImportedCopy(_ url: URL) {
            // Delete only the importer's sandbox copy, never the selected source file.
            let file = url.standardizedFileURL.resolvingSymlinksInPath()
            let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
            let inbox = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
                .appendingPathComponent("Inbox", isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
            if file.path.hasPrefix(temporary) || inbox.map({ file.path.hasPrefix($0 + "/") }) == true {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
