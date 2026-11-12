import CoreML
import Foundation

/// What the lab's models do, for the rest of the engine: say what kind an image is, give an image's embedding
/// (for finding similar images), cut a subject out, and upscale. Each downloads its model the first time it's
/// needed (`ModelStore`), as a job on `jobs`.
nonisolated public struct Models: Sendable {
    public let store: ModelStore
    public let jobs: Jobs

    public init(store: ModelStore, jobs: Jobs) {
        self.store = store
        self.jobs = jobs
    }
}

nonisolated extension Lab {
    /// The models, kept in `data/models/`.
    public var models: Models {
        Models(store: ModelStore.shared(root: store.root.appendingPathComponent("models")), jobs: jobs)
    }
}
