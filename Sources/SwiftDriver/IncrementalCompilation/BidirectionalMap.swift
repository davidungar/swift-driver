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

/// Like a two-way dictionary, but with only the functionality needed for the driver
///
public struct BidirectionalMap<T1: Hashable, T2: Hashable>: Equatable, Sequence {
  private var map1: [T1: T2] = [:]
  private var map2: [T2: T1] = [:]

  public init() {}

  /// Accesses the value associated with the given key for reading and writing.
  ///
  /// - Parameter key: The key to find in the dictionary.
  /// - Returns: The value associated with key if key is in the bidirectional
  /// map; otherwise, `nil`.
  public subscript(_ key: T1) -> T2? {
    get {
      Self.lookup(key, map1, map2)
    }
  }

  /// Accesses the value associated with the given key for reading and writing.
  ///
  /// - Parameter key: The key to find in the dictionary.
  /// - Returns: The value associated with key if key is in the bidirectional
  /// map; otherwise, `nil`.
  public subscript(_ key: T2) -> T1? {
    get {
      Self.lookup(key, map2, map1)
    }
  }

  public func contains(key: T1) -> Bool {
    map1.keys.contains(key)
  }
  public func contains(key: T2) -> Bool {
    map2.keys.contains(key)
  }

  public mutating func updateValue(_ newValue: T2, forKey key: T1) -> T2? {
    Self.updateValue(newValue, forKey: key, &map1, &map2)
  }
  public mutating func updateValue(_ newValue: T1, forKey key: T2) -> T1? {
    Self.updateValue(newValue, forKey: key, &map2, &map1)
  }

  public func makeIterator() -> Dictionary<T1, T2>.Iterator {
    map1.makeIterator()
  }
}

// MARK: - factoring bidirectionality
extension BidirectionalMap {
  static fileprivate func lookup<K: Hashable, V: Hashable>(
    _ key: K, _ forwardMap: [K: V], _ reverseMap: [V: K]) -> V? {
    guard let v = forwardMap[key] else {
      return nil
    }
    assert(reverseMap[v] == key)
    return v
  }

  @discardableResult
  static fileprivate func updateValue<K: Hashable, V: Hashable>(
    _ newValue: V, forKey key: K, _ forwardMap: inout [K: V], _ reverseMap: inout [V: K]
    ) -> V? {
    let oldValue = forwardMap.updateValue(newValue, forKey: key)
    _ = oldValue.map {reverseMap.removeValue(forKey: $0)}
    reverseMap[newValue] = key
    return oldValue
  }
}
