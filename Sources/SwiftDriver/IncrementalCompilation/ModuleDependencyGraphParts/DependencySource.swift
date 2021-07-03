//===------------------------ Node.swift ----------------------------------===//
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

// MARK: - DependencySource
/// Points to the source of dependencies, i.e. the file read to obtain the information.
public protocol DependencySourceX: CustomStringConvertible {

  var typedFile: TypedVirtualPath {get}
  var file: VirtualPath {get}
  var shortDescription: String {get}
  var fileHandle: VirtualPath.Handle {get}
  static var fileType: FileType {get}
}

extension DependencySourceX {
  public var description: String {
    ExternalDependency(fileName: file.name).description // DMU
  }

  public var file: VirtualPath {
    VirtualPath.lookup(fileHandle)
  }
  public var typedFile: TypedVirtualPath {
    TypedVirtualPath(file: fileHandle, type: Self.fileType)
  }
}

public func createDependencySource(_ typedFile: TypedVirtualPath) -> DependencySourceX? {
  switch typedFile.type {
  case .swiftDeps:   return SwiftDepsDependencySource(  fileHandle: typedFile.fileHandle)
  case .swiftModule: return SwiftModuleDependencySource(fileHandle: typedFile.fileHandle)
  default: return nil
  }
}

public func createDependencySource(_  fileHandle: VirtualPath.Handle) -> DependencySourceX {
  let path = VirtualPath.lookup(fileHandle)
  let ext = path.extension
  switch ext {
  case FileType.swiftDeps.rawValue:
    return SwiftDepsDependencySource(fileHandle: fileHandle)
  case FileType.swiftModule.rawValue:
    return SwiftModuleDependencySource(fileHandle: fileHandle)
  default:
    fatalError("bad extension \(String(describing: ext))")
  }
}

public struct SwiftDepsDependencySource: DependencySourceX, Hashable {
  public let fileHandle: VirtualPath.Handle
  public var shortDescription: String { file.basename }
  public static var fileType = FileType.swiftDeps
  public init(checking typedFile: TypedVirtualPath) {
    assert(typedFile.type == Self.fileType)
    self.fileHandle = typedFile.fileHandle
  }
  public init(fileHandle: VirtualPath.Handle) {
    assert( VirtualPath.lookup(fileHandle).extension == Self.fileType.rawValue)
    self.fileHandle = fileHandle
  }
}

public struct SwiftModuleDependencySource: DependencySourceX, Hashable {
  public let fileHandle: VirtualPath.Handle
  public var shortDescription: String { file.parentDirectory.basename }
  public static var fileType = FileType.swiftModule
  public init(checking typedFile: TypedVirtualPath) {
    assert(typedFile.type == Self.fileType)
    self.fileHandle = typedFile.fileHandle
  }
  public init(fileHandle: VirtualPath.Handle) {
    assert( VirtualPath.lookup(fileHandle).extension == Self.fileType.rawValue)
    self.fileHandle = fileHandle
  }

}



// MARK: - reading
extension DependencySourceX {
  /// Throws if a read error
  /// Returns nil if no dependency info there.
  public func read(
    in fileSystem: FileSystem,
    reporter: IncrementalCompilationState.Reporter?
  ) -> SourceFileDependencyGraph? {
    let graphIfPresent: SourceFileDependencyGraph?
    do {
      graphIfPresent = try SourceFileDependencyGraph.read(
        from: self,
        on: fileSystem)
    }
    catch {
      let msg = "Could not read \(file) \(error.localizedDescription)"
      reporter?.report(msg, typedFile)
      return nil
    }
    return graphIfPresent
  }
}

