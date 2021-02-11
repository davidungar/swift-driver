//===--------------- Set+Extensions.swift - Incremental -------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2019 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

extension Sequence {
  public func flatMapToSet<Outputs: Sequence, Output: Hashable>
  (transform: (Element) -> Outputs) -> Set<Output>
  where Outputs.Element == Output
  {
    var r = Set<Output>()
    for input in self {
      r.formUnion(transform(input))
    }
    return r
  }
}
