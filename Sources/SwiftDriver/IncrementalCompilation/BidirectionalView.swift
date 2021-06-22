//===------------------ BidirectionalMap.swift ----------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation

/// Provides an immutable bidirectional view of a unidirectional map.
///
public struct BidirectionalView<ForwardKey: Hashable, ReverseKey: Hashable>: Equatable {

  private let forwardLookup: (ForwardKey) -> ReverseKey?
  private let reverseMap: [ReverseKey: ForwardKey]

  /// Create the view, failing if some key has no value
  ///
  /// - Parameters:
  /// - keys: The universe of forward keys
  /// - forwardLookup: The function to find a (forward) value from a (forward) key
  /// - Returns: A completed view if every key has a unique value. Throws exceptions otherwise.
  fileprivate init(_ forwardLookup: @escaping (ForwardKey) -> ReverseKey?,
  _ reverseMap: [ReverseKey: ForwardKey]) {
    self.forwardLookup = forwardLookup
    self.reverseMap = reverseMap
  }

  public enum ConstructionResult {
  case success(BidirectionalView<ForwardKey, ReverseKey>)
  case failure(missingValues: [ForwardKey], nonuniqueValues: Multidictionary<ReverseKey, ForwardKey>)
  }

  public static func constructOrFail<Keys: Sequence>(
    _ keys: Keys, _ forwardLookup: @escaping (ForwardKey) -> ReverseKey?)
  -> ConstructionResult
  where Keys.Element == ForwardKey
  {
    var missingValues = [ForwardKey]()
    var nonuniqueValues = Multidictionary<ReverseKey, ForwardKey>()
    let reverseMap = keys.reduce(into: [ReverseKey: ForwardKey]()) {
      reverseMap, key in
      guard let value = forwardLookup(key) else {
        missingValues.append(key)
        return
      }
      if let oldKey = reverseMap.updateValue(key, forKey: value) {
        nonuniqueValues.insertValue(key, forKey: value)
        nonuniqueValues.insertValue(oldKey, forKey: value)
      }
    }
    guard missingValues.isEmpty && nonuniqueValues.isEmpty else {
      return .failure(missingValues: missingValues, nonuniqueValues: nonuniqueValues)
    }
    return .success(Self(forwardLookup, reverseMap))
  }

  /// Accesses the value associated with the given key for reading and writing.
  ///
  /// - Parameter key: The key to find in the dictionary.
  /// - Returns: The value associated with key if key is in the bidirectional
  /// map; otherwise, `nil`.
  public subscript(_ key: ForwardKey) -> ReverseKey? {
    forwardLookup(key)
  }

  /// Accesses the value associated with the given key for reading and writing.
  ///
  /// - Parameter key: The key to find in the dictionary.
  /// - Returns: The value associated with key if key is in the bidirectional
  /// map; otherwise, `nil`.
   public subscript(_ key: ReverseKey) -> ForwardKey? {
    reverseMap[key]
  }

  public static func == (lhs: BidirectionalView<ForwardKey, ReverseKey>, rhs: BidirectionalView<ForwardKey, ReverseKey>) -> Bool {
    lhs.reverseMap == rhs.reverseMap
  }
}
// MAReverseKey: - Errors
extension BidirectionalView {
  enum MappingError: LocalizedError {
    case missingValue(ForwardKey),
         nonuniqueValue(ForwardKey, ForwardKey, ReverseKey)

    var errorDescription: String? {
      switch self {
      case let .missingValue(forwardKey):
        return "Missing value for key \(forwardKey)"
      case let .nonuniqueValue(key, otherKey, value):
        return "Duplicate values \(value) for \(key) and \(otherKey)"
      }
    }
  }
}
