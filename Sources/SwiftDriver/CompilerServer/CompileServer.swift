//===-------------------- CompileServer.swift ----------------------------===//
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

public struct CompileServer {
  let pid: Int
  let process: CompileServerProcess
  public let dynamicBatchingLog: TSCBasic.OSLog?
  var sourceFile: VirtualPath? = nil

  //var buf = Array<UInt8>(repeating: 0, count: 100000)

  var sourceFileNameFD: Int32 { process.sourceFileNamePipe.fileHandleForWriting.fileDescriptor}
  var     completionFD: Int32 { process    .completionPipe.fileHandleForReading.fileDescriptor}

  init(env: [String: String], job: Job, resolver: ArgsResolver, forceResponseFiles: Bool,
       dynamicBatchingLog: TSCBasic.OSLog?) {
    do {
      let arguments: [String] = try resolver.resolveArgumentList(for: job,
                                                                 forceResponseFiles: forceResponseFiles)
      self.dynamicBatchingLog = dynamicBatchingLog
      let process = CompileServerProcess(arguments: arguments,
                                         environment: env,
                                         dynamicBatchingLog: dynamicBatchingLog)
      self.process = process
      try process.launch()

      //dmuxxx MyLog.log("launched") //dmuxxx
      self.pid = Int(process.processID)
    }
    catch let error as SystemError {
      if case let .posix_spawn(rv, arguments)  = error {
        print("SystemError.posix_spawn", rv, arguments)
        fatalError("launchCompileServer")
      }
      print("cannot launch compile server", error.localizedDescription)
      fatalError("launchCompileServer")
    }
    catch {
      print("cannot launch compile server", error.localizedDescription)
      fatalError("launchCompileServer")
    }
  }

  public mutating func writeSourceFileName(_ job: Job) {
    let pris = job.primaryInputs
    assert(pris.count == 1)
    let sf = pris[0].file
    sourceFile = sf
    let wrres = write(sourceFileNameFD, sf.name, sf.name.count)
    if wrres != sf.name.count {
      abort()
    }
    //dmuxxx MyLog.log("wrote name ", sourceFileNameFD, pri)
  }

  public mutating func readCompletion() {
    var buf = Array<UInt8>(repeating: 0, count: 1000)
    //dmuxxx MyLog.log("about to read completion of \(sourceFile?.basename ?? "???")", completionFD)
    let rres = withUnsafeMutablePointer(to: &buf) { read(completionFD, $0, 1) }
    //dmuxxx MyLog.log("read completion of \(sourceFile?.basename ?? "???")", completionFD)
    if rres != 1 {
      //dmuxxx MyLog.log("bad read of \(sourceFile?.basename ?? "???")", rres, errno, to: &stderrStream); stderrStream.flush()
    }
  }

  public func getOutputs() ->  ([UInt8], [UInt8]) {
    process.getOutputs()
  }
  func terminate() {
    close(sourceFileNameFD)
    // MyLog.log("*")
  }
}




