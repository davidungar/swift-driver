//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import TSCBasic

public struct DynamicBatchingLog {
  private let log: TSCBasic.OSLog?

  init(enable: Bool) {
    self.log =
      enable ? TSCBasic.OSLog(subsystem: "com.apple.SwiftDriver", category: "dynamicBatching") : nil
  }

  public func log(_ message: @autoclosure () -> String) {
    log.map {os_log(log: $0, "%s", message())}
  }
}
