import Foundation
import Testing
@testable import MeshCore

struct BackgroundWorkTests {
    @Test func cancellationReachesDetachedOperation() async throws {
        let started = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let task = Task {
            try await BackgroundWork.run {
                started.continuation.yield(())
                release.wait()
                try Task.checkCancellation()
                return 42
            }
        }
        for await _ in started.stream { break }
        task.cancel()
        release.signal()
        await #expect(throws: CancellationError.self) { try await task.value }
        started.continuation.finish()
    }

    @MainActor
    @Test func cancelledLoadDoesNotOpenFile() async {
        let task = Task {
            try await ModelLoader.load(url: URL(fileURLWithPath: "/missing/cancelled.obj"))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
