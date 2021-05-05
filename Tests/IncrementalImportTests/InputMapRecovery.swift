//===---------------- InputMapRecovery.swift - Swift Testing ------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import XCTest
import IncrementalTestFramework

// Under some circumstances--probably involving reading priors--the
// `inputDependencySourceMap` can fail to provide an input for a
// `DependencySource`. Ensure that the driver will recover gracefully.

class InputMapRecoveryTest: XCTestBase {
  func testInputMapRecovery() throws {
    let mainSource = Source(named: "main", containing: "3 + 4")
    let mainModule = Module(named: "MainModule",
                            containing: [mainSource],
                            producing: .executable)
    try IncrementalTest.perform(
      [
        Step(building: modules, .expecting(modules.allSourcesToCompile)),
        Step(building: modules, .expecting(.none))],
      ZapMapStep(),
      Step(building: modules, .expecting(modules.allSourcesToCompile)),
      Step(building: modules, .expecting(.none))])
  }

}
