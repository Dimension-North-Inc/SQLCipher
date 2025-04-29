//
//  SQLAction.swift
//  SQLCipher
//
//  Created by Mark Onyschuk on 12/3/24.
//  Copyright © 2024 Dimension North Inc. All rights reserved.
//

import Foundation

/// A protocol defining a single, state-modifying action within an `SQLCipherStore`.
///
/// Conforming types represent discrete updates to the store's state, optionally interacting with its underlying database.
/// Actions can be pending, undoable, or critical, as specified by their `type`.
///
/// - Note: Use this protocol for simple, synchronous state changes. For long-running operations, see `SQLCompositeAction`.
public protocol SQLAction<State> {
    /// The state type this action operates on, conforming to `Stored`.
    associatedtype State: Stored

    /// Performs the action, modifying the provided state and optionally interacting with the database.
    /// - Parameters:
    ///   - state: The current state, passed as an `inout` parameter for modification.
    ///   - db: An `SQLConnection` for database operations, such as querying or writing.
    /// - Throws: An error if the update fails (e.g., due to database issues).
    func update(state: inout State, db: SQLConnection) throws
    
    /// Specifies the update's persistence and undo behavior.
    /// Defaults to `.ephemeral` if not overridden.
    var type: UpdateType { get }
}

extension SQLAction {
    /// The default update type, marking the action as temporary and non-persistent.
    public var type: UpdateType {
        return .pending
    }
}

/// Defines the persistence and undo behavior of an `SQLAction`.
public enum UpdateType {
    /// An unpdate persisted with the next undoable or critical update.
    case pending
    /// An immediately persisted update which can be undone to some earlier state..
    case undoable
    /// An immediately persisted update which forms a new state baseline that can not be undone..
    case critical
}

/// Represents the progress of a long-running `SQLCompositeAction`.
///
/// Progress is reported as a value between 0.0 and 1.0 (or -1 for unspecified progress), accompanied by a descriptive message.
public struct SQLActionProgress: Sendable {
    /// The progress value, where:
    /// - 0.0 to 1.0 indicates a percentage complete.
    /// - -1 indicates unspecified progress (e.g., indeterminate tasks).
    public let progress: Double
    
    /// A human-readable description of the current step or status.
    public let description: String
    
    /// Private initializer enforcing controlled creation via static methods.
    private init(progress: Double, description: String = "") {
        self.progress = progress
        self.description = description
    }
    
    /// Creates a progress update with unspecified completion (indeterminate).
    /// - Parameter description: A message describing the current operation.
    /// - Returns: A new `SQLActionProgress` instance with `progress` set to -1.
    public static func unspecified(_ description: String) -> Self {
        Self(progress: -1, description: description)
    }
    
    /// Creates a progress update for a specific step in a sequence.
    /// - Parameters:
    ///   - step: The current step number (starting at 1).
    ///   - total: The total number of steps.
    ///   - description: An optional message describing the step.
    /// - Returns: A new `SQLActionProgress` instance with progress as `step / total`.
    public static func step(_ step: Int, of total: Int, description: String = "") -> Self {
        Self(progress: Double(step) / Double(total), description: description)
    }
}

/// A protocol defining a long-running, asynchronous composite action for an `SQLCipherStore`.
///
/// Conforming types encapsulate complex operations (e.g., importing data, processing files) that report progress over time.
/// Unlike `SQLAction`, these are executed asynchronously and managed via `SQLTask`.
public protocol SQLCompositeAction<State> {
    /// The state type this action operates on.
    associatedtype State
    
    /// Executes the composite action, updating the store and reporting progress.
    /// - Parameters:
    ///   - store: The `SQLCipherStore` instance to operate on.
    ///   - advance: A closure to report progress updates during execution.
    /// - Throws: An error if the operation fails.
    func execute(
        store: SQLCipherStore<State>,
        advance: @escaping (SQLActionProgress) -> Void
    ) async throws
}

/// A reference type for tracking and managing a long-running composite action.
///
/// `SQLTask` instances are created by `SQLCipherStore.dispatch` and provide status updates, cancellation, and user-defined metadata.
/// As an `@Observable` type, it’s ideal for SwiftUI integration.
///
/// - Note: This class is bound to the main actor for UI safety.
@MainActor @Observable public final class SQLTask<State, UserInfo> {
    /// A unique identifier for the task.
    public let id: UUID
    
    /// User-provided metadata associated with the task (e.g., filename, context).
    public let userInfo: UserInfo
    
    /// The current status of the task, updated as the operation progresses.
    public var status: SQLActionStatus = .pending
    
    /// The underlying `Task` executing the composite action.
    private var task: Task<Void, Error>?
    
    /// Initializes a new task with the given user info.
    /// - Parameter userInfo: Custom metadata to associate with the task.
    public init(userInfo: UserInfo) {
        self.id = UUID()
        self.userInfo = userInfo
    }
    
    /// Starts the task with the provided asynchronous operation.
    /// - Parameter operation: The async closure to execute.
    func start(_ operation: @escaping () async throws -> Void) {
        task = Task {
            try await operation()
        }
    }
    
    /// Cancels the running task, if active.
    public func cancel() {
        task?.cancel()
    }
}

/// Represents the current state of an `SQLTask` during execution.
///
/// This enum tracks the lifecycle of a composite action, from initiation to completion or failure.
/// It conforms to `Equatable` for status comparisons.
public enum SQLActionStatus: Equatable {
    /// The task has been created but not yet started.
    case pending
    
    /// The task is actively running, with a progress value and description.
    /// - `progress`: A value from 0.0 to 1.0, or -1 for unspecified.
    /// - `description`: A message about the current operation.
    case running(progress: Double, description: String)
    
    /// The task is paused (not currently implemented).
    case paused
    
    /// The task has completed successfully.
    case completed
    
    /// The task was cancelled by the user or system.
    case cancelled
    
    /// The task failed with an error.
    case failed(Error)
    
    /// Compares two status values for equality.
    /// - Parameters:
    ///   - lhs: The left-hand status.
    ///   - rhs: The right-hand status.
    /// - Returns: `true` if the statuses are equivalent, `false` otherwise.
    public static func == (lhs: SQLActionStatus, rhs: SQLActionStatus) -> Bool {
        switch (lhs, rhs) {
        case (.pending, .pending),
             (.completed, .completed),
             (.cancelled, .cancelled):
            return true
        case (.running(let p1, let d1), .running(let p2, let d2)):
            return p1 == p2 && d1 == d2
        case (.failed(let e1), .failed(let e2)):
            return e1.localizedDescription == e2.localizedDescription
        default:
            return false
        }
    }
}

extension Notification.Name {
    /// A notification posted by `SQLCipherStore` when a new `SQLTask` is created for a composite action.
    ///
    /// The notification's `object` is the newly created `SQLTask` instance. Consumers (e.g., a task manager or UI)
    /// can observe this to track long-running operations without tightly coupling to the store.
    ///
    /// - Example:
    ///   ```swift
    ///   NotificationCenter.default.addObserver(
    ///       forName: .storeDidCreateTask,
    ///       object: nil,
    ///       queue: .main
    ///   ) { notification in
    ///       if let task = notification.object as? SQLTask<MyState, String> {
    ///           print("New task created: \(task.userInfo)")
    ///       }
    ///   }
    ///   ```
    public static let storeDidCreateTask = Notification.Name("storeDidCreateTask")
}

// MARK: - Store Extension

extension SQLCipherStore {
    /// Dispatches a synchronous action to update the store's state.
    ///
    /// This method applies the action’s `update` transformation to the current state,
    /// handling persistence and undo/redo based on the action’s `type`.
    /// - Parameter action: The `SQLAction` to execute.
    @MainActor
    public func dispatch<A: SQLAction>(_ action: A) where A.State == State {
        self.update(action.type, transform: action.update)
    }
    
    /// Dispatches an asynchronous composite action, returning a task to track its execution.
    ///
    /// This method initiates a long-running operation defined by the `SQLCompositeAction`, creating an `SQLTask`
    /// to manage its lifecycle. The task’s status is updated as progress is reported, and a notification
    /// (`.storeDidCreateTask`) is posted to signal its creation.
    ///
    /// - Parameters:
    ///   - action: The `SQLCompositeAction` to execute.
    ///   - userInfo: Custom metadata to associate with the task (e.g., a filename or context).
    ///   - priority: An optional `TaskPriority` to control execution priority (defaults to `nil`).
    /// - Returns: An `SQLTask` instance for monitoring progress, cancellation, or completion.
    /// - Note: The result is marked `@discardableResult` since consumers may ignore the task if they observe notifications instead.
    /// - Example:
    ///   ```swift
    ///   let task = store.dispatch(MyCompositeAction(), userInfo: "file.jpg", priority: .userInitiated)
    ///   print(task.id) // Track manually, or rely on .storeDidCreateTask notification
    ///   ```
    @MainActor @discardableResult
    public func dispatch<A: SQLCompositeAction, UserInfo>(
        _ action: A,
        userInfo: UserInfo,
        priority: TaskPriority? = nil
    ) -> SQLTask<State, UserInfo> where A.State == State {
        let task = SQLTask<State, UserInfo>(userInfo: userInfo)
        
        // Start the task
        task.start { [weak self] in
            guard let self = self else { return }
            
            do {
                let stream = AsyncThrowingStream<SQLActionProgress, Error> { continuation in
                    let advance: (SQLActionProgress) -> Void = {
                        progress in continuation.yield(progress)
                    }
                    
                    Task(priority: priority) {
                        do {
                            try await action.execute(store: self, advance: advance)
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                }
                
                // Consume the stream and update task status
                for try await progress in stream {
                    if Task.isCancelled { throw CancellationError() }
                    task.status = .running(
                        progress: progress.progress,
                        description: progress.description
                    )
                }
                
                task.status = .completed
            } catch is CancellationError {
                task.status = .cancelled
            } catch {
                task.status = .failed(error)
            }
        }
        
        NotificationCenter.default.post(name: .storeDidCreateTask, object: task)
        
        return task
    }
}
