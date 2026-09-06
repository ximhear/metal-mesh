import Foundation

public enum BackgroundWork {
    public static func run<Value: Sendable>(
        priority: TaskPriority = .userInitiated,
        operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let task = Task.detached(priority: priority) {
            try Task.checkCancellation()
            let value = try operation()
            try Task.checkCancellation()
            return value
        }
        return try await withTaskCancellationHandler {
            let value = try await task.value
            try Task.checkCancellation()
            return value
        } onCancel: {
            task.cancel()
        }
    }
}
