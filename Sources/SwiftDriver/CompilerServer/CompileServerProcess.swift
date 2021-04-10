//===-------------- CompileServerProcess.swift ---------------------------===//
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
import TSCLibc


public final class CompileServerProcess: ObjectIdentifierProtocol {
  /// The arguments with which the process was launched.
  public let arguments: [String]

  /// The environment with which the process was launched.
  public let environment: [String: String]

  /// The output bytes of the process. Available only if the process was
  /// asked to redirect its output and no stdout output closure was set.
  private var stdout = [UInt8]()

  /// The output bytes of the process. Available only if the process was
  /// asked to redirect its output and no stderr output closure was set.
  private var stderr = [UInt8]()

  /// The process id of the spawned process, available after the process is launched.
   public private(set) var processID = Process.ProcessID()

  /// Pipes must stay alive for the duration
  let stdoutPipe = Pipe()
  let stderrPipe = Pipe()
  let sourceFileNamePipe = Pipe()
  let completionPipe = Pipe()

  var stdoutThread: TSCBasic.Thread?
  var stderrThread: TSCBasic.Thread?

  let stdoutLock = Lock()
  let stderrLock = Lock()



  /// Create an instance using a POSIX process exit status code and output result.å
  ///
  /// See `waitpid(2)` for information on the exit status code.
  public init(
      arguments: [String],
      environment: [String: String]
  ) {
    self.arguments = arguments
    self.environment = environment
  }
}

extension CompileServerProcess {


  func launch() throws {
    precondition(arguments.count > 0 && !arguments[0].isEmpty, "Need at least one argument to launch the process.")

    #if !os(macOS)
    fatalError()
    #else

    var attributes: posix_spawnattr_t? =  setupSignals()
    defer { posix_spawnattr_destroy(&attributes) }

    // Workaround for https://sourceware.org/git/gitweb.cgi?p=glibc.git;h=89e435f3559c53084498e9baad22172b64429362
    // Change allowing for newer version of glibc
    guard let devNull = strdup("/dev/null") else {
      throw SystemError.posix_spawn(0, arguments)
    }
    defer { free(devNull) }
    var fileActions = setupFileDescriptors(devNull)
    defer { posix_spawn_file_actions_destroy(&fileActions) }

    try spawn(&attributes, &fileActions, &processID)

    closeParentProcessFileDescriptors()

    stdoutThread = startOutputReader(stdoutPipe) { [weak self] bytes in self?.stdoutLock.withLock {self?.stdout += bytes} }
    stdoutThread = startOutputReader(stderrPipe) { [weak self] bytes in self?.stderrLock.withLock {self?.stderr += bytes} }

    #endif // POSIX implementation
  }

  private func setupSignals() -> posix_spawnattr_t? {
    var attributes: posix_spawnattr_t? = nil
    posix_spawnattr_init(&attributes)

    // Unmask all signals.
    var noSignals = sigset_t()
    sigemptyset(&noSignals)
    posix_spawnattr_setsigmask(&attributes, &noSignals)

    // Reset all signals to default behavior.
    var mostSignals = sigset_t()
    sigfillset(&mostSignals)
    sigdelset(&mostSignals, SIGKILL)
    sigdelset(&mostSignals, SIGSTOP)
    posix_spawnattr_setsigdefault(&attributes, &mostSignals)

    // Set the attribute flags.
    var flags = POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
      // Establish a separate process group.
    flags |= POSIX_SPAWN_SETPGROUP
    posix_spawnattr_setpgroup(&attributes, 0)

    posix_spawnattr_setflags(&attributes, Int16(flags))

    return attributes
  }

  private func setupFileDescriptors(_ devNull: UnsafeMutablePointer<Int8>) -> posix_spawn_file_actions_t? {
    var fileActions: posix_spawn_file_actions_t? = nil
    // Setup the file actions.
    posix_spawn_file_actions_init(&fileActions)

    // Open /dev/null as stdin.
    do {
      let r = posix_spawn_file_actions_addopen(&fileActions, 0, devNull, O_RDONLY, 0)
      if r != 0 {fatalError()}
    }

    posix_spawn_file_actions_adddup2(&fileActions,         stdoutPipe.fileHandleForWriting.fileDescriptor, Int32(1))
    posix_spawn_file_actions_adddup2(&fileActions,         stderrPipe.fileHandleForWriting.fileDescriptor, Int32(2))
    posix_spawn_file_actions_adddup2(&fileActions, sourceFileNamePipe.fileHandleForReading.fileDescriptor, Int32(3))
    posix_spawn_file_actions_adddup2(&fileActions,     completionPipe.fileHandleForWriting.fileDescriptor, Int32(4))

    [
      [stdoutPipe, stderrPipe, completionPipe].map {$0.fileHandleForReading},
      [sourceFileNamePipe.fileHandleForWriting]
    ].joined()
    .map {$0.fileDescriptor}
    .filter {$0 > 4}
    .forEach {posix_spawn_file_actions_addclose(&fileActions, $0)}

    return fileActions
  }

  private func spawn(_ attributes: inout posix_spawnattr_t?,
                     _ fileActions: inout posix_spawn_file_actions_t?,
                     _ processID: inout TSCBasic.Process.ProcessID
  ) throws {
    let argv = CStringArray(arguments + ["-experimental-dynamic-batching", "-no-color-diagnostics"])
    let env = CStringArray(environment.map({ "\($0.0)=\($0.1)" }))
    let rv = posix_spawnp(&processID, argv.cArray[0]!, &fileActions, &attributes, argv.cArray, env.cArray)

    guard rv == 0 else {
      throw SystemError.posix_spawn(rv, arguments)
    }
  }

  private func closeParentProcessFileDescriptors() {
    [
      [stdoutPipe, stderrPipe, completionPipe].map {$0.fileHandleForWriting},
      [sourceFileNamePipe.fileHandleForReading]
    ].joined()
    .map {$0.fileDescriptor}
    .forEach {close($0)}
  }

  private func startOutputReader(_ pipe: Pipe, _ emit: @escaping (ArraySlice<UInt8>) -> Void) -> TSCBasic.Thread {
    let fd = pipe.fileHandleForReading.fileDescriptor
    let thread = TSCBasic.Thread {
      let N = 4096
      var buf = [UInt8](repeating: 0, count: N + 1)
      var error: Int32? = nil
      while error == nil {
        let n = read(fd, &buf, N)
        precondition(n >= -1)
        switch n {
        case -1 where errno == EINTR:
          break
        case -1:
          error = errno
          break
        case 0:
          error = 0
          break
        default:
          emit(buf[0..<n])
        }
      }
      close(fd)
    }
    thread.start()
    return thread
  }

  func getOutputs() ->  ([UInt8], [UInt8]) {
    func get(_ lock: Lock, _ buf: inout [UInt8]) -> [UInt8] {
      lock.withLock {
        let r = buf
        buf.removeAll()
        return r
      }
    }
    return (
      get(stdoutLock, &stdout),
      get(stderrLock, &stderr))
  }
}
