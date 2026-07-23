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

    /// Relays child changes, such as an external mod install, to the store on the main actor.
    func presentedSubitemDidChange(at url: URL) { Task { @MainActor in onChange() } }
    /// Relays replacement or metadata changes to the store on the main actor.
    func presentedItemDidChange() { Task { @MainActor in onChange() } }
}
