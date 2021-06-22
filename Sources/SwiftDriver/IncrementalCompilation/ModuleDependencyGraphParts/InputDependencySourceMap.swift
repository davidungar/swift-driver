//===------------- InputDependencySourceMap.swift ---------------- --------===//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
import Foundation
import TSCBasic

@_spi(Testing) public struct InputDependencySourceMap: Equatable {
  
  /// Maps input files (e.g. .swift) to and from the DependencySource object.
  ///
  // This map caches the same information as in the `OutputFileMap`, but it
  // optimizes the reverse lookup, and includes path interning via `DependencySource`.
  // Once created, it does not change.
  
  public typealias BiMap = BidirectionalView<TypedVirtualPath, DependencySource>
  @_spi(Testing) public let biMap: BiMap

  /// Based on entries in the `OutputFileMap`, create the bidirectional map to map each source file
  /// path to- and from- the corresponding swiftdeps file path.
  ///
  /// - Returns: the map, or nil if error
  init?(_ info: IncrementalCompilationState.IncrementalDependencyAndInputSetup) {
    let outputFileMap = info.outputFileMap
    let diagnosticEngine = info.diagnosticEngine

    assert(outputFileMap.onlySourceFilesHaveSwiftDeps())
    let swiftInputFiles = info.inputFiles.lazy.filter {$0.type == .swift}
    let biMapOrFailure = BiMap.constructOrFail(swiftInputFiles) {
        input in
        outputFileMap.getDependencySource(for: input)
    }
    switch biMapOrFailure {
    case .success(let biMap):
      self.biMap = biMap
    case let .failure(missingValues, nonuniqueValues):
      assert(!missingValues.isEmpty || !nonuniqueValues.isEmpty)
      for inputName in (missingValues.map {$0.file.basename}.sorted()) {
        // The legacy driver fails silently here.
        diagnosticEngine.emit(
          .remarkDisabled("\(inputName) has no swiftDeps file")
        )
      }
      for (dependencySource, inputs) in nonuniqueValues.sorted(by: {$0.0 < $1.0})  {
        diagnosticEngine.emit(
          .remarkDisabled(
            "\(inputs.map {$0.file.name}.sorted().joined(separator: ",")) have the same swiftdeps file in the ouput file map: \(dependencySource.file.name)"))
      }
            return nil
    }
  }
}

// MARK: - Accessing
extension InputDependencySourceMap {
  @_spi(Testing) public func sourceIfKnown(for input: TypedVirtualPath) -> DependencySource? {
    biMap[input]
  }

  @_spi(Testing) public func inputIfKnown(for source: DependencySource) -> TypedVirtualPath? {
    biMap[source]
  }
}

extension OutputFileMap {
  @_spi(Testing) public func getDependencySource(
    for sourceFile: TypedVirtualPath
  ) -> DependencySource? {
    assert(sourceFile.type == FileType.swift)
    guard let swiftDepsPath = existingOutput(inputFile: sourceFile.fileHandle,
                                             outputType: .swiftDeps)
    else {
      return nil
   }
    assert(VirtualPath.lookup(swiftDepsPath).extension == FileType.swiftDeps.rawValue)
    let typedSwiftDepsFile = TypedVirtualPath(file: swiftDepsPath, type: .swiftDeps)
    return DependencySource(typedSwiftDepsFile)
  }
}
