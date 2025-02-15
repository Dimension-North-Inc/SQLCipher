//
//  SQLAction.swift
//  SQLCipher
//
//  Created by Mark Onyschuk on 12/3/24.
//  Copyright © 2024 Dimension North Inc. All rights reserved.
//

import Foundation

/// A protocol that defines a single state-modifying action within a `SQLCipherStore`.
public protocol SQLAction<State> {
    associatedtype State: Stored

    /// Performs the action, updating the state and optionally interacting with the database.
    func update(state: inout State, db: SQLConnection) throws
    
    var type: UpdateType { get }
}

extension SQLAction {
    public var type: UpdateType {
        return .ephemeral
    }
}

public enum UpdateType {
    case ephemeral
    case undoable
    case critical
}

/// Represents the progress of a composite action
public struct SQLActionProgress: Sendable {
    public let progress: Double
    public let description: String
    
    public init(progress: Double, description: String) {
        self.progress = progress
        self.description = description
    }
}

public typealias SQLCompositeActionContinuation = AsyncThrowingStream<SQLActionProgress, any Error>.Continuation

/// Protocol defining a long-running composite action
public protocol SQLCompositeAction<State> {
    associatedtype State
    
    /// Executes the composite action
    func execute(
        store: SQLCipherStore<State>,
        yield: SQLCompositeActionContinuation
    ) async throws
}

/// Reference type for tracking a running composite action
@MainActor @Observable public final class SQLTask<State, UserInfo> {
    public let id: UUID
    public let userInfo: UserInfo
    
    public var status: SQLActionStatus = .pending
    
    private var task: Task<Void, Error>?
    
    init(userInfo: UserInfo) {
        self.id = UUID()
        self.userInfo = userInfo
    }
    
    func start(_ operation: @escaping () async throws -> Void) {
        task = Task {
            try await operation()
        }
    }
    
    public func cancel() {
        task?.cancel()
    }
}

/// Status representing the current state of a composite action
public enum SQLActionStatus: Equatable {
    case pending
    case running(progress: Double, description: String)
    case paused
    case completed
    case cancelled
    case failed(Error)
    
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

// MARK: - Store Extension

extension SQLCipherStore {
    /// Dispatches an action for execution
    @MainActor
    public func dispatch<A: SQLAction>(_ action: A)
    where A.State == State {
        self.update(action.type, transform: action.update)
    }
    
    /// Dispatches a composite action for execution
    @MainActor @discardableResult
    public func dispatch<A: SQLCompositeAction, UserInfo>(
        _ action: A,
        userInfo: UserInfo
    ) -> SQLTask<State, UserInfo> where A.State == State {
        let task = SQLTask<State, UserInfo>(userInfo: userInfo)
        
        // Start the task
        task.start { [weak self] in
            guard let self = self else { return }
            
            do {
                let stream = AsyncThrowingStream<SQLActionProgress, Error> { yield in
                    Task {
                        do {
                            try await action.execute(store: self, yield: yield)
                            yield.finish()
                        } catch {
                            yield.finish(throwing: error)
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
        
        return task
    }
}
