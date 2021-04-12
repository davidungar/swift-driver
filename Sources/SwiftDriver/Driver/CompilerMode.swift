//===--------------- CompilerMode.swift - Swift Compiler Mode -------------===//
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
/// The mode of the compiler.
@_spi(Testing) public enum CompilerMode: Equatable {
  /// A standard compilation, using multiple frontend invocations and -primary-file.
  case standardCompile

  /// A batch compilation, using multiple frontend invocations with
  /// multiple -primary-file options per invocation.
  case batchCompile(BatchModeInfo)

  /// Still experimental; dynamically hand out tasks to compile servers.
  case dynamicBatchCompile(debugDynamicBatching: Bool)

  /// A compilation using a single frontend invocation without -primary-file.
  case singleCompile

  /// Invoke the REPL.
  case repl

  /// Compile and execute the inputs immediately.
  case immediate

  /// Compile a Clang module (.pcm).
  case compilePCM
}

/// Information about batch mode, which is used to determine how to form
/// the batches of jobs.
@_spi(Testing) public struct BatchModeInfo: Equatable {
  let seed: Int?
  let count: Int?
  let sizeLimit: Int?

  @_spi(Testing) public init(seed: Int?, count: Int?, sizeLimit: Int?) {
    self.seed = seed
    self.count = count
    self.sizeLimit = sizeLimit
  }
}

extension CompilerMode {
  /// Whether this compilation mode uses -primary-file to specify its inputs.
  public var usesPrimaryFileInputs: Bool {
    switch self {
    case .immediate, .repl, .singleCompile, .compilePCM:
      return false

    case .standardCompile, .batchCompile, .dynamicBatchCompile:
      return true
    }
  }

  /// Whether this compilation mode compiles the whole target in one job.
  public var isSingleCompilation: Bool {
    switch self {
    case .immediate, .repl, .standardCompile, .batchCompile, .dynamicBatchCompile:
      return false

    case .singleCompile, .compilePCM:
      return true
    }
  }

  public var isStandardCompilationForPlanning: Bool {
    switch self {
      case .immediate, .repl, .compilePCM:
        return false
    case .batchCompile, .dynamicBatchCompile, .standardCompile, .singleCompile:
        return true
    }
  }

  public var batchModeInfo: BatchModeInfo? {
    switch self {
    case let .batchCompile(info):
      return info
    default:
      return BatchModeInfo(seed: nil, count: 1, sizeLimit: Int.max)
    }
  }

  public var isBatchCompile: Bool {
    batchModeInfo != nil
  }

  // Whether this compilation mode supports the use of bridging pre-compiled
  // headers.
  public var supportsBridgingPCH: Bool {
    switch self {
    case .batchCompile, .dynamicBatchCompile, .singleCompile, .standardCompile, .compilePCM:
      return true
    case .immediate, .repl:
      return false
    }
  }

  public var isDynamicBatch: Bool {
    switch self {
    case .dynamicBatchCompile: return true
    default: return false
    }
  }

  public var debugDynamicBatching: Bool {
    switch self {
    case .dynamicBatchCompile(let debugDynamicBatching):
      return debugDynamicBatching
    default: return false
    }
  }
}

extension CompilerMode: CustomStringConvertible {
    public var description: String {
      switch self {
      case .standardCompile:
        return "standard compilation"
      case .batchCompile:
        return "batch compilation"
      case .dynamicBatchCompile:
        return "dynamic batch compilation"
      case .singleCompile:
        return "whole module optimization"
      case .repl:
        return "read-eval-print-loop compilation"
      case .immediate:
        return "immediate compilation"
      case .compilePCM:
        return "compile Clang module (.pcm)"
      }
  }
}
