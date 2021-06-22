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

class BidirectionalMapTests: XCTestCase {

  func testBiDiMap() {
    func test(_ biMapToTest: BidirectionalMap<Int, String>) {
      zip(biMapToTest.map{$0}.sorted {$0.0 < $1.0}, testContents).forEach {
        XCTAssertEqual($0.0, $1.0)
        XCTAssertEqual($0.1, $1.1)
      }
      for (i, s) in testContents.map({$0}) {
        XCTAssertEqual(biMapToTest[i], s)
        XCTAssertEqual(biMapToTest[s], i)
        XCTAssertTrue(biMapToTest.contains(key: i))
        XCTAssertTrue(biMapToTest.contains(key: s))
        XCTAssertFalse(biMapToTest.contains(key: -1))
        XCTAssertFalse(biMapToTest.contains(key: "gazorp"))
      }
    }
    
    var biMap = BidirectionalMap<Int, String>()
    let testContents = (0..<3).map {($0, String($0))}
    for (i, s) in testContents {
      XCTAssertNil(biMap.updateValue(s, forKey: i))
    }
    test(biMap)
  }

  func testDirectionality() {
    var biMap = BidirectionalMap<Int, String>()
    XCTAssertNil(biMap.updateValue("Hello", forKey: 1))
    XCTAssertEqual(biMap["Hello"], 1)
    XCTAssertEqual(biMap[1], "Hello")
    XCTAssertNil(biMap.updateValue("World", forKey: 2))
    XCTAssertEqual(biMap["World"], 2)
    XCTAssertEqual(biMap[2], "World")

    XCTAssertNil(biMap.updateValue("World", forKey: 3))
    XCTAssertEqual(biMap["World"], 3)
    XCTAssertEqual(biMap[3], "World")
    XCTAssertNil(biMap.updateValue("Hello", forKey: 4))
    XCTAssertEqual(biMap["Hello"], 4)
    XCTAssertEqual(biMap[4], "Hello")
  }
}
