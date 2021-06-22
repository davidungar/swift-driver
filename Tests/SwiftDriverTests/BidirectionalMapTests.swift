//===------------------------ BidirectionalMapTests.swift -----------------===//
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

import XCTest
import SwiftDriver

class BidirectionalViewTests: XCTestCase {
  func testBiDiView() {
    struct Fixture {
      let forwardMap: [Int: String]
      let expectation: BidirectionalView<Int, String>.ConstructionResult
      let missingValues: [Int]
      let nonuniqueValues: Multidictionary<String, Int>

      init(_ forwardMap: [Int: String],
           _ expectation: BidirectionalView<Int, String>.ConstructionResult,
           _ missingValues: [Int],
           _ nonuniqueValues: Multidictionary<String, Int>) {
        self.forwardMap = forwardMap
        self.expectation = expectation
        self.missingValues = missingValues
        self.nonuniqueValues = nonuniqueValues
      }

      func test() {
        let r = BidirectionalView.constructOrFail(forwardMap.keys) {k in forwardMap[k]}
        switch r {
        case let .success(biView):
          for (k, v) in forwardMap {
            XCTAssert(missingValues.isEmpty && nonuniqueValues.isEmpty)
            XCTAssertEqual(k, biView[v])
            XCTAssertEqual(v, biView[k])
          }
        case let .failure(missingValues, nonuniqueValues):
          XCTAssert(!missingValues.isEmpty || !nonuniqueValues.isEmpty)
          XCTAssert(missingValues == self.missingValues)
          XCTAssert(nonuniqueValues == self.nonuniqueValues)
        }
      }

      static let testCases: [Self] = [
        Self([1: "one", 2: "two", 3: "three"], .success)
        Self[1: "one", ]
      ]
    }


  }
}
