//
//  SQLStoreUndoable.swift
//  SQLCipher
//
//  Created by Mark Onyschuk on 12/3/24.
//  Copyright © 2024 Dimension North Inc. All rights reserved.
//

import Foundation


/// A marker protocol that declares an action as undoable.
///
/// Conforming types signal to the store that the state prior to their execution
/// should be marked as undoable. The store will automatically create an undo point
/// before executing any undoable action.
///
/// - Note: Combine `SQLStoreUndoable` with `SQLStoreAction` or `SQLStoreCompositeAction`
/// to ensure actions are undoable.
public protocol SQLStoreUndoable {}
