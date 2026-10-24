import Foundation

/// Constructed on the owner actor, then transferred once to a detached worker.
/// Only that worker mutates/releases the contained resources. Native destructors
/// therefore cannot freeze the main actor while a model is replaced.
final class NativeResourceDisposal: @unchecked Sendable {
    private var resources: [Any]
    init(resources: [Any]) { self.resources = resources }
    func dispose() { resources.removeAll() }
}
