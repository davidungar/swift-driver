//===--------------- SetOfInvalidated.swift -------------------------------===//
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

/// A type to hold things that are invalidated (and will need to cause compilations)

public struct SetOfInvalidated<Thing: Hashable>: Sequence {
  var things: Set<Thing>
  init<Things:Sequence>(_ things: Things)
  where Things.Element == Thing {
    self.things = Set(things)
  }
  init() { self.things = Set() }
  mutating func formUnion(_ other: Self) {
    things.formUnion(other.things)
  }
  mutating func insert(_ thing: Thing) {
      things.insert(thing)
    }
    public func makeIterator() -> Set<Thing>.Iterator {
      things.makeIterator()
    }
}
extension Sequence {
  func conditionalCompactMapToChanges<Output: Hashable, Outputs: Sequence>
  (transform: (Element) -> Outputs?) -> SetOfInvalidated<Output>?
  where Outputs.Element == Output
  {
    var r = Set<Output>()
    for input in self {
      guard let outputs = transform(input) else {
        return nil
      }
      r.formUnion(outputs)
    }
    return SetOfInvalidated(r)
  }
  #warning("dmu find better names")
  public func mapIntoInvalidatedThings<Output: Hashable>(transform: (Element) -> Output)
  -> SetOfInvalidated<Output> {
    var r = Set<Output>()
    for thing in self {
      r.insert(transform(thing))
    }
    return SetOfInvalidated<Output>(r)
  }
  public func compactmapIntoInvalidatedThings<Output: Hashable>(transform: (Element) -> Output?)
  -> SetOfInvalidated<Output> {
    var r = Set<Output>()
    for thing in self {
      if let x = transform(thing) {
        r.insert(x)
      }
    }
    return SetOfInvalidated<Output>(r)
  }
}

public typealias InvalidatedNodes = SetOfInvalidated<ModuleDependencyGraph.Node>
public typealias InvalidatedSources = SetOfInvalidated<DependencySource>
public typealias InvalidatedInputs = SetOfInvalidated<TypedVirtualPath>

extension InvalidatedNodes {
  var nodes: Set<ModuleDependencyGraph.Node> { things }
}
extension InvalidatedSources {
  var sources: Set<DependencySource> { things }
}
extension InvalidatedInputs {
  var inputs: Set<TypedVirtualPath> { things }
}
