import Foundation

nonisolated final class ModsFolderPresenter: NSObject, NSFilePresenter {
    var presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue.main
    private let onChange: @MainActor () -> Void

    /// Registers a directory URL and main-actor callback for external Files-app modifications.
    init(url: URL, onChange: @escaping @MainActor () -> Void) {
        presentedItemURL = url
        self.onChange = onChange
    }

    func presentedSubitemDidChange(at url: URL) { Task { @MainActor in onChange() } }
    func presentedItemDidChange() { Task { @MainActor in onChange() } }
}
