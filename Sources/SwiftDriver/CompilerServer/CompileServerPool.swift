//===------------------ CompileServerPool.swift --------------------------===//
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
import TSCBasic


/// Compiler servers
public struct CompileServerPool {
  private let compileServerQueue: DispatchQueue = DispatchQueue(label: "com.apple.swift-driver.compile-servers", qos: .userInteractive)
  private var freeCompileServers: [CompileServer]

  public let dynamicBatchingLog: DynamicBatchingLog


  public init?(_ incrementalCompilationState: IncrementalCompilationState?,
       numServers: Int,
       env: [String: String],
       argsResolver: ArgsResolver,
       forceResponseFiles: Bool
      ) {
    guard let incrementalCompilationState = incrementalCompilationState,
          let compileServerJob = incrementalCompilationState.compileServerJob
    else {
      return nil
    }
    let debugDynamicBatching = incrementalCompilationState.debugDynamicBatching

    self.dynamicBatchingLog = DynamicBatchingLog(enable: debugDynamicBatching)

    var freeCompileServers = [CompileServer]()
    freeCompileServers.reserveCapacity(numServers)
    dynamicBatchingLog.log("Creating \(numServers) servers")
    for i in 0..<numServers {
      dynamicBatchingLog.log("Creating \(i)")
      freeCompileServers.append(CompileServer(env: env,
                                              job: compileServerJob,
                                              resolver: argsResolver,
                                              forceResponseFiles: forceResponseFiles,
                                              dynamicBatchingLog: dynamicBatchingLog))
      dynamicBatchingLog.log("Created \(i)")
    }
    dynamicBatchingLog.log("Finished all servers")
    self.freeCompileServers = freeCompileServers

    assert( Set(freeCompileServers.map {$0.sourceFileNameFD}).count == freeCompileServers.count)
  }

  mutating public func acquireCompileServer() -> CompileServer {
    compileServerQueue.sync {
      if freeCompileServers.isEmpty {
        abort() // launchCompileServer first N times, then what??
      }
      return freeCompileServers.removeLast()
    }
  }
  mutating public func releaseCompileServer(_ cs: CompileServer) {
    compileServerQueue.sync {
      freeCompileServers.append(cs)
    }
  }
  mutating public func terminateAll() {
    compileServerQueue.sync {
      freeCompileServers.forEach {$0.terminate()}
    }
  }
}
