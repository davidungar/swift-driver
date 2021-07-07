//===------- ModuleDependencyGraph.swift ----------------------------------===//
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
import TSCUtility
import SwiftOptions


// MARK: - ModuleDependencyGraph

/// Holds all the dependency relationships in this module, and declarations in other modules that
/// are dependended-upon.
/*@_spi(Testing)*/ public final class ModuleDependencyGraph {

  @_spi(Testing) public var nodeFinder = NodeFinder()

  // The set of paths to external dependencies known to be in the graph
  public internal(set) var fingerprintedExternalDependencies = Set<FingerprintedExternalDependency>()

  /// A lot of initial state that it's handy to have around.
  @_spi(Testing) public let info: IncrementalCompilationState.IncrementalDependencyAndInputSetup

  /// For debugging, something to write out files for visualizing graphs
  let dotFileWriter: DependencyGraphDotFileWriter?

  @_spi(Testing) public var phase: Phase

  /// The phase when the graph was created. Used to help diagnose later failures
  let creationPhase: Phase

  fileprivate var currencyCache: ExternalDependencyCurrencyCache

  public init?(_ info: IncrementalCompilationState.IncrementalDependencyAndInputSetup,
               _ phase: Phase
  ) {
    self.currencyCache = ExternalDependencyCurrencyCache(
      info.fileSystem, buildStartTime: info.buildStartTime)
    self.info = info
    self.dotFileWriter = info.emitDependencyDotFileAfterEveryImport
    ? DependencyGraphDotFileWriter(info)
    : nil
    self.phase = phase
    self.creationPhase = phase
  }
}

extension ModuleDependencyGraph {
  public enum Phase {
    /// Building a graph from swiftdeps files
    case buildingWithoutAPrior

    /// Building a graph by reading a prior graph
    /// and updating for changed external dependencies
    case updatingFromAPrior

    /// Updating a graph from a `swiftdeps` file for an input that was just compiled
    /// Or, updating a graph from a `swiftmodule` file (i.e. external dependency) that was transitively found to be
    /// added as the `swiftdeps` file was processed.
    case updatingAfterCompilation

    /// This is a clean incremental build. All inputs are being compiled and after each compilation,
    /// the graph is being built from the new `swiftdeps` file.
    case buildingAfterEachCompilation

    var isUpdating: Bool {
      switch self {
      case .buildingWithoutAPrior, .buildingAfterEachCompilation:
        return false
      case .updatingAfterCompilation, .updatingFromAPrior:
        return true
      }
    }
  }
}

// MARK: - Building from swiftdeps
extension ModuleDependencyGraph {
  /// Integrates `input` as needed and returns any inputs that were invalidated by external dependencies
  /// When creating a graph from swiftdeps files, this operation is performed for each input.
  func collectInputsRequiringCompilationFromExternalsFoundByCompiling(
    input: TypedVirtualPath
  ) -> TransitivelyInvalidatedInputSet? {
    // do not try to read swiftdeps of a new input
    if info.sourceFiles.isANewInput(input.file) {
      return TransitivelyInvalidatedInputSet()
    }
    return collectInputsRequiringCompilationAfterProcessing(input: input)
  }
}

// MARK: - Getting a graph read from priors ready to use
extension ModuleDependencyGraph {
  func collectNodesInvalidatedByChangedOrAddedExternals() -> DirectlyInvalidatedNodeSet {
    fingerprintedExternalDependencies.reduce(into: DirectlyInvalidatedNodeSet()) {
      invalidatedNodes, fed in
      invalidatedNodes.formUnion(self.incrementallyFindNodesInvalidated(
        by: ExternalIntegrand(fed, shouldBeIn: self)))
    }
  }
}

// MARK: - Scheduling the first wave
extension ModuleDependencyGraph {
  /// Find all the sources that depend on `changedInput`.
  ///
  /// For some source files, these will be speculatively scheduled in the first wave.
  /// - Parameter changedInput: The input file that changed since the last build
  /// - Returns: The input files that must be recompiled, excluding `changedInput`
  func collectInputsInvalidatedBy(changedInput: TypedVirtualPath
  ) -> TransitivelyInvalidatedInputArray {
    let changedSource = DependencySource(changedInput)
    let allUses = collectInputsUsing(dependencySource: changedSource)

    return allUses.filter {
      user in
      guard user != changedInput else {return false}
      info.reporter?.report(
        "Found dependent of \(changedInput.file.basename):", user)
      return true
    }
  }

  /// Find all the input files that depend on `dependencySource`.
  /// Really private, except for testing.
  /*@_spi(Testing)*/ public func collectInputsUsing(
    dependencySource: DependencySource
  ) -> TransitivelyInvalidatedInputSet {
    let nodes = nodeFinder.findNodes(for: dependencySource) ?? [:]
    /// Tests expect this to be reflexive
    return collectInputsUsingInvalidated(nodes: DirectlyInvalidatedNodeSet(nodes.values))
  }

  /// Does the graph contain any dependency nodes for a given source-code file?
  func containsNodes(forSourceFile file: TypedVirtualPath) -> Bool {
    precondition(file.type == .swift)
    return containsNodes(forDependencySource: DependencySource(file))
  }

  func containsNodes(forDependencySource source: DependencySource) -> Bool {
    return nodeFinder.findNodes(for: source).map {!$0.isEmpty}
      ?? false
  }
}


// MARK: - Scheduling the 2nd wave
extension ModuleDependencyGraph {
  /// After `source` has been compiled, figure out what other source files need compiling.
  /// Used to schedule the 2nd wave.
  ///
  /// - Parameter input: The file that has just been compiled
  /// - Returns: The input files that must be compiled now that `input` has been compiled.
  /// These may include inptus that do not need compilation because this build already compiled them.
  /// In case of an error, such as a missing entry in the `OutputFileMap`, nil is returned.
  func collectInputsRequiringCompilation(byCompiling input: TypedVirtualPath
  ) -> TransitivelyInvalidatedInputSet? {
    return collectInputsRequiringCompilationAfterProcessing(input: input)
  }
}

// MARK: - Scheduling either wave
extension ModuleDependencyGraph {
  
  /// Given nodes that are invalidated, find all the affected inputs that must be recompiled.
  ///
  /// - Parameter nodes: A set of graph nodes for changed declarations.
  /// - Returns: All source files containing declarations that transitively depend upon the changed declarations.
  public func collectInputsUsingInvalidated(
    nodes: DirectlyInvalidatedNodeSet
  ) -> TransitivelyInvalidatedInputSet
  {
    // Is this correct for the 1st wave after having read a prior?
    // Yes, because
    //  1. if the externalDependency was current, there are no changes required
    //  2. otherwise, it will have been reread, which should create changed nodes, etc.
    let affectedNodes = Tracer.collectPreviouslyUntracedNodesUsing(
      defNodes: nodes,
      in: self,
      diagnosticEngine: info.diagnosticEngine)
      .tracedUses
    return affectedNodes.reduce(into: TransitivelyInvalidatedInputSet()) {
      invalidatedInputs, affectedNode in
      if let source = affectedNode.dependencySource,
          source.typedFile.type == .swift {
        invalidatedInputs.insert(source.typedFile)
      }
    }
  }

  /// Is this source file part of this build?
  ///
  /// - Parameter sourceFile: the Swift source-code file in question
  /// - Returns: true iff this file was in the command-line invocation of the driver
  fileprivate func isPartOfBuild(_ sourceFile: TypedVirtualPath) -> Bool {
    info.sourceFiles.currentSet.contains(sourceFile.fileHandle)
  }

  /// Given an external dependency & its fingerprint, find any nodes directly using that dependency.
  ///
  /// - Parameters:
  ///   - fingerprintedExternalDependency: the dependency to trace
  ///   - why: why the dependecy must be traced
  /// - Returns: any nodes that directly use (depend upon) that external dependency.
  /// As an optimization, only return the nodes that have not been already traced, because the traced nodes
  /// will have already been used to schedule jobs to run.
  public func collectUntracedNodes(
    thatUse externalDefs: FingerprintedExternalDependency,
    _ why: ExternalDependency.InvalidationReason
  ) -> DirectlyInvalidatedNodeSet {
    // These nodes will depend on the *interface* of the external Decl.
    let key = DependencyKey(
      aspect: .interface,
      designator: .externalDepend(externalDefs.externalDependency))
    // DependencySource is OK as a nil placeholder because it's only used to find
    // the corresponding implementation node and there won't be any for an
    // external dependency node.
    let node = Node(key: key,
                    fingerprint: externalDefs.fingerprint,
                    dependencySource: nil)
    let untracedUses = DirectlyInvalidatedNodeSet(
      nodeFinder
        .uses(of: node)
        .filter({ use in use.isUntraced }))
    info.reporter?.reportInvalidated(untracedUses, by: externalDefs.externalDependency, why)
    return untracedUses
  }

  /// Find all the inputs known to need recompilation as a consequence of processing a swiftdeps file.
  ///
  /// - Parameter input: The input file whose swiftdeps file contains the dependencies to be read and integrated.
  /// - Returns: `nil` on error, or the inputs discovered to be requiring compilation.
  private func collectInputsRequiringCompilationAfterProcessing(
    input: TypedVirtualPath
  ) -> TransitivelyInvalidatedInputSet? {
    assert(input.type == .swift)
    let dependencySource = DependencySource(input)
    guard let sourceGraph = dependencySource.read(info: info)
    else {
      // to preserve legacy behavior cancel whole thing
      info.diagnosticEngine.emit(
        .remark_incremental_compilation_has_been_disabled(
          because: "malformed dependencies file '\(dependencySource.fileToRead(info: info)?.file.name ?? "none?!")'"))
      return nil
    }
    let invalidatedNodes = Integrator.integrate(
      from: sourceGraph,
      dependencySource: dependencySource,
      into: self)
    return collectInputsInBuildUsingInvalidated(nodes: invalidatedNodes)
  }

  /// Computes the set of inputs that must be recompiled as a result of the
  /// invalidation of the given list of nodes.
  ///
  /// If the set of invalidated nodes could not be computed because of a failure
  /// to match a swiftdeps file to its corresponding input file, this function
  /// return `nil`. This can happen when e.g. the build system changes the
  /// entries in the output file map out from under us.
  ///
  /// - Parameter directlyInvalidatedNodes: The set of invalidated nodes.
  /// - Returns: The set of inputs that were transitively invalidated, if
  ///            possible. Or `nil` if such a set could not be computed.
  func collectInputsInBuildUsingInvalidated(
    nodes directlyInvalidatedNodes: DirectlyInvalidatedNodeSet
  ) -> TransitivelyInvalidatedInputSet? {
    var invalidatedInputs = TransitivelyInvalidatedInputSet()
    for invalidatedInput in collectInputsUsingInvalidated(nodes: directlyInvalidatedNodes) {
      guard isPartOfBuild(invalidatedInput)
      else {
        info.diagnosticEngine.emit(
          warning: "Failed to find source file '\(invalidatedInput.file.basename)' in command line, recovering with a full rebuild. Next build will be incremental.")
        return nil
      }
      invalidatedInputs.insert(invalidatedInput)
    }
    return invalidatedInputs
  }
}

// MARK: - Integrating External Dependencies

extension ModuleDependencyGraph {
  /// The kinds of external dependencies available to integrate.
  enum ExternalIntegrand {
    /// An `old` integrand is one that, when found, is known to already be in ``ModuleDependencyGraph/fingerprintedExternalDependencies``
    case old(FingerprintedExternalDependency)
    /// A `new` integrand is one that, when found was not already in ``ModuleDependencyGraph/fingerprintedExternalDependencies``
    case new(FingerprintedExternalDependency)

    init(_ fed: FingerprintedExternalDependency,
         in graph: ModuleDependencyGraph ) {
      self = graph.fingerprintedExternalDependencies.insert(fed).inserted
      ? .old(fed)
      : .new(fed)
    }

    init(_ fed: FingerprintedExternalDependency,
         shouldBeIn graph: ModuleDependencyGraph ) {
      assert(graph.fingerprintedExternalDependencies.contains(fed))
      self = .old(fed)
    }


    var externalDependency: FingerprintedExternalDependency {
      switch self {
      case .new(let fed), .old(let fed): return fed
      }
    }
  }

  /// Find the nodes *directly* invaliadated by some external dependency
  ///
  /// This function does not do the transitive closure; that is left to the callers.
  func findNodesInvalidated(
    by integrand: ExternalIntegrand
  ) -> DirectlyInvalidatedNodeSet {
    self.info.isCrossModuleIncrementalBuildEnabled
    ?    incrementallyFindNodesInvalidated(by: integrand)
    : indiscriminatelyFindNodesInvalidated(by: integrand)
  }

  /// Collects the nodes invalidated by a change to the given external
  /// dependency after integrating it into the dependency graph.
  /// Use best-effort to integrate incrementally, by reading the `swiftmodule` file.
  ///
  /// This function does not do the transitive closure; that is left to the
  /// callers.
  ///
  /// - Parameter integrand: The external dependency to integrate.
  /// - Returns: The set of module dependency graph nodes invalidated by integration.
  func incrementallyFindNodesInvalidated(
    by integrand: ExternalIntegrand
  ) -> DirectlyInvalidatedNodeSet {
    assert(self.info.isCrossModuleIncrementalBuildEnabled)

    guard let whyIntegrate = whyIncrementallyFindNodesInvalidated(by: integrand) else {
      return DirectlyInvalidatedNodeSet()
    }
    return integrateIncrementalImport(of: integrand.externalDependency, whyIntegrate)
           ?? indiscriminatelyFindNodesInvalidated(by: integrand)
  }

  /// Collects the nodes invalidated by a change to the given external
  /// dependency after integrating it into the dependency graph.
  ///
  /// Do not try to be incremental; do not read the `swiftmodule` file.
  ///
  /// This function does not do the transitive closure; that is left to the
  /// callers.
  /// If called when incremental imports is enabled, it's a fallback.
  ///
  /// - Parameter integrand: The external dependency to integrate.
  /// - Returns: The set of module dependency graph nodes invalidated by integration.
  private func indiscriminatelyFindNodesInvalidated(
    by integrand: ExternalIntegrand
  ) -> DirectlyInvalidatedNodeSet {
    if let reason = whyIndiscriminatelyFindNodesInvalidated(by: integrand) {
      return collectUntracedNodes(thatUse: integrand.externalDependency, reason)
    }
    return DirectlyInvalidatedNodeSet()
  }

  /// Figure out the reason to integrate, (i.e. process) a dependency that will be read and integrated.
  ///
  /// Even if invalidation won't be reported to the caller, a new or added
  /// incremental external dependencies may require integration in order to
  /// transitively close them, (e.g. if an imported module imports a module).
  ///
  /// - Parameter fed: The external dependency, with fingerprint and origin info to be integrated
  /// - Returns: nil if no integration is needed, or else why the integration is happening
  private func whyIncrementallyFindNodesInvalidated(by integrand: ExternalIntegrand
  ) -> ExternalDependency.InvalidationReason? {
   switch integrand {
   case .new:
      return .added
   case .old where self.currencyCache.isCurrent(integrand.externalDependency.externalDependency):
      // The most current version is already in the graph
      return nil
    case .old:
      return .changed
    }
  }

  /// Compute the reason for (non-incrementally) invalidating nodes
  ///
  /// Parameter integrand: The exernal dependency causing the invalidation
  /// Returns: nil if no invalidation is needed, otherwise the reason.
  private func whyIndiscriminatelyFindNodesInvalidated(by integrand: ExternalIntegrand
  ) -> ExternalDependency.InvalidationReason? {
    switch self.phase {
    case .buildingWithoutAPrior, .updatingFromAPrior:
      // If the external dependency has changed, better recompile any dependents
      return self.currencyCache.isCurrent(integrand.externalDependency.externalDependency)
      ? nil : .changed
    case .updatingAfterCompilation:
      // Since this file has been compiled anyway, no need
      return nil
    case .buildingAfterEachCompilation:
      // No need to do any invalidation; every file will be compiled anyway
      return nil
    }
  }

  /// Try to read and integrate an external dependency.
  ///
  /// Return: nil if an error occurs, or the set of directly affected nodes.
  private func integrateIncrementalImport(
    of fed: FingerprintedExternalDependency,
    _ why: ExternalDependency.InvalidationReason
  ) -> DirectlyInvalidatedNodeSet? {
    guard
      let source = fed.incrementalDependencySource,
      let unserializedDepGraph = source.read(info: info)
    else {
      return nil
    }
    let invalidatedNodes = Integrator.integrate(
      from: unserializedDepGraph,
      dependencySource: source,
      into: self)
    info.reporter?.reportInvalidated(invalidatedNodes, by: fed.externalDependency, why)
    // When doing incremental imports, never read the same swiftmodule twice
    self.currencyCache.beCurrent(fed.externalDependency)
    return invalidatedNodes
  }

  /// Remember if an external dependency need not be integrated in order to avoid redundant work.
  ///
  /// If using incremental imports, a given build should not read the same `swiftmodule` twice:
  /// Because when using incremental imports, the whole graph is present, a single read of a `swiftmodule`
  /// can invalidate any input file that depends on a changed external declaration.
  ///
  /// If not using incremental imports, a given build may have to invalidate nodes more than once for the same `swiftmodule`:
  /// For example, on a clean build, as each initial `swiftdeps` is integrated, if the file uses a changed `swiftmodule`,
  /// iit must be scheduled for recompilation. Thus invalidation happens for every dependent input file.
  fileprivate struct ExternalDependencyCurrencyCache {
    private let fileSystem: FileSystem
    private let buildStartTime: Date
    private var currencyCache = [ExternalDependency: Bool]()

    init(_ fileSystem: FileSystem, buildStartTime: Date) {
      self.fileSystem = fileSystem
      self.buildStartTime = buildStartTime
    }

    mutating func beCurrent(_ externalDependency: ExternalDependency) {
      self.currencyCache[externalDependency] = true
    }

    mutating func isCurrent(_ externalDependency: ExternalDependency) -> Bool {
      if let cachedResult = self.currencyCache[externalDependency] {
        return cachedResult
      }
      let uncachedResult = isCurrentWRTFileSystem(externalDependency)
      self.currencyCache[externalDependency] = uncachedResult
      return uncachedResult
    }

    private func isCurrentWRTFileSystem(_ externalDependency: ExternalDependency) -> Bool {
      if let depFile = externalDependency.path,
         let fileModTime = try? self.fileSystem.lastModificationTime(for: depFile),
         fileModTime < self.buildStartTime {
        return true
      }
      return false
    }
  }
}

// MARK: - tracking traced nodes
extension ModuleDependencyGraph {

 func ensureGraphWillRetrace(_ nodes: DirectlyInvalidatedNodeSet) {
   for node in nodes {
      node.setUntraced()
    }
  }
}

// MARK: - verification
extension ModuleDependencyGraph {
  @discardableResult
  @_spi(Testing) public func verifyGraph() -> Bool {
    nodeFinder.verify()
  }
}
// MARK: - Serialization

extension ModuleDependencyGraph {
  /// The leading signature of this file format.
  fileprivate static let signature = "DDEP"
  /// The expected version number of the serialized dependency graph.
  ///
  /// - WARNING: You *must* increment the minor version number when making any
  ///            changes to the underlying serialization format.
  ///
  /// - Minor number 1: Don't serialize the `inputDepedencySourceMap`
  /// - Minor number 2: Use `.swift` files instead of `.swiftdeps` in ``DependencySource``
  @_spi(Testing) public static let serializedGraphVersion = Version(1, 2, 0)

  /// The IDs of the records used by the module dependency graph.
  fileprivate enum RecordID: UInt64 {
    case metadata           = 1
    case moduleDepGraphNode = 2
    case dependsOnNode      = 3
    case useIDNode          = 4
    case externalDepNode    = 5
    case identifierNode     = 6

    /// The human-readable name of this record.
    ///
    /// This data is emitted into the block info field for each record so tools
    /// like llvm-bcanalyzer can be used to more effectively debug serialized
    /// dependency graphs.
    var humanReadableName: String {
      switch self {
      case .metadata:
        return "METADATA"
      case .moduleDepGraphNode:
        return "MODULE_DEP_GRAPH_NODE"
      case .dependsOnNode:
        return "DEPENDS_ON_NODE"
      case .useIDNode:
        return "USE_ID_NODE"
      case .externalDepNode:
        return "EXTERNAL_DEP_NODE"
      case .identifierNode:
        return "IDENTIFIER_NODE"
      }
    }
  }

  @_spi(Testing) public enum ReadError: Error {
    case badMagic
    case noRecordBlock
    case malformedMetadataRecord
    case mismatchedSerializedGraphVersion(expected: Version, read: Version)
    case unexpectedMetadataRecord
    case malformedFingerprintRecord
    case malformedIdentifierRecord
    case malformedModuleDepGraphNodeRecord
    case malformedDependsOnRecord
    case malformedMapRecord
    case malformedExternalDepNodeRecord
    case unknownRecord
    case unexpectedSubblock
    case bogusNameOrContext
    case unknownKind
    case unknownDependencySourceExtension
  }

  /// Attempts to read a serialized dependency graph from the given path.
  ///
  /// - Parameters:
  ///   - path: The absolute path to the file to be read.
  ///   - fileSystem: The file system on which to search.
  ///   - diagnosticEngine: The diagnostics engine.
  ///   - reporter: An optional reporter used to log information about
  /// - Throws: An error describing any failures to read the graph from the given file.
  /// - Returns: A fully deserialized ModuleDependencyGraph, or nil if nothing is there
  @_spi(Testing) public static func read(
    from path: VirtualPath,
    info: IncrementalCompilationState.IncrementalDependencyAndInputSetup
  ) throws -> ModuleDependencyGraph? {
    guard try info.fileSystem.exists(path) else {
      return nil
    }
    let data = try info.fileSystem.readFileContents(path)

    struct Visitor: BitstreamVisitor {
      private let fileSystem: FileSystem
      private let graph: ModuleDependencyGraph
      var majorVersion: UInt64?
      var minorVersion: UInt64?
      var compilerVersionString: String?

      // The empty string is hardcoded as identifiers[0]
      private var identifiers: [String] = [""]
      private var currentDefKey: DependencyKey? = nil
      private var nodeUses: [(DependencyKey, Int)] = []
      public private(set) var allNodes: [Node] = []

      init?(_ info: IncrementalCompilationState.IncrementalDependencyAndInputSetup) {
        self.fileSystem = info.fileSystem
        guard let graph = ModuleDependencyGraph(info, .updatingFromAPrior)
        else {
          return nil
        }
        self.graph = graph
      }

      func finalizeGraph() -> ModuleDependencyGraph {
        for (dependencyKey, useID) in self.nodeUses {
          let isNewUse = self.graph.nodeFinder
            .record(def: dependencyKey, use: self.allNodes[useID])
          assert(isNewUse, "Duplicate use def-use arc in graph?")
        }
        return self.graph
      }

      func validate(signature: Bitcode.Signature) throws {
        guard signature == .init(string: ModuleDependencyGraph.signature) else {
          throw ReadError.badMagic
        }
      }

      mutating func shouldEnterBlock(id: UInt64) throws -> Bool {
        return true
      }

      mutating func didExitBlock() throws {}

      private mutating func finalize(node newNode: Node) {
        self.allNodes.append(newNode)
        let oldNode = self.graph.nodeFinder.insert(newNode)
        assert(oldNode == nil,
               "Integrated the same node twice: \(oldNode!), \(newNode)")
      }

      mutating func visit(record: BitcodeElement.Record) throws {
        guard let kind = RecordID(rawValue: record.id) else {
          throw ReadError.unknownRecord
        }

        switch kind {
        case .metadata:
          // If we've already read metadata, this is an unexpected duplicate.
          guard self.majorVersion == nil, self.minorVersion == nil, self.compilerVersionString == nil else {
            throw ReadError.unexpectedMetadataRecord
          }
          guard record.fields.count == 2,
                case .blob(let compilerVersionBlob) = record.payload
          else { throw ReadError.malformedMetadataRecord }

          self.majorVersion = record.fields[0]
          self.minorVersion = record.fields[1]
          self.compilerVersionString = String(decoding: compilerVersionBlob, as: UTF8.self)
        case .moduleDepGraphNode:
          let kindCode = record.fields[0]
          guard record.fields.count == 7,
                let declAspect = DependencyKey.DeclAspect(record.fields[1]),
                record.fields[2] < identifiers.count,
                record.fields[3] < identifiers.count,
                case .blob(let fingerprintBlob) = record.payload
          else {
            throw ReadError.malformedModuleDepGraphNodeRecord
          }
          let context = identifiers[Int(record.fields[2])]
          let identifier = identifiers[Int(record.fields[3])]
          let designator = try DependencyKey.Designator(
            kindCode: kindCode, context: context, name: identifier, fileSystem: fileSystem)
          let key = DependencyKey(aspect: declAspect, designator: designator)
          let hasDepSource = Int(record.fields[4]) != 0
          let depSourceStr = hasDepSource ? identifiers[Int(record.fields[5])] : nil
          let hasFingerprint = Int(record.fields[6]) != 0
          let fingerprint = hasFingerprint ? String(decoding: fingerprintBlob, as: UTF8.self) : nil
          guard let dependencySource = try depSourceStr
                  .map({ try VirtualPath.intern(path: $0) })
                  .map(DependencySource.init)
          else {
            throw ReadError.unknownDependencySourceExtension
          }
          self.finalize(node: Node(key: key,
                                   fingerprint: fingerprint,
                                   dependencySource: dependencySource))
        case .dependsOnNode:
          let kindCode = record.fields[0]
          guard record.fields.count == 4,
                let declAspect = DependencyKey.DeclAspect(record.fields[1]),
                record.fields[2] < identifiers.count,
                record.fields[3] < identifiers.count
          else {
            throw ReadError.malformedDependsOnRecord
          }
          let context = identifiers[Int(record.fields[2])]
          let identifier = identifiers[Int(record.fields[3])]
          let designator = try DependencyKey.Designator(
            kindCode: kindCode, context: context, name: identifier, fileSystem: fileSystem)
          self.currentDefKey = DependencyKey(aspect: declAspect, designator: designator)
        case .useIDNode:
          guard let key = self.currentDefKey, record.fields.count == 1 else {
            throw ReadError.malformedDependsOnRecord
          }
          self.nodeUses.append( (key, Int(record.fields[0])) )
        case .externalDepNode:
          guard record.fields.count == 2,
                record.fields[0] < identifiers.count,
                case .blob(let fingerprintBlob) = record.payload
          else {
            throw ReadError.malformedExternalDepNodeRecord
          }
          let path = identifiers[Int(record.fields[0])]
          let hasFingerprint = Int(record.fields[1]) != 0
          let fingerprint = hasFingerprint ? String(decoding: fingerprintBlob, as: UTF8.self) : nil
          self.graph.fingerprintedExternalDependencies.insert(
            FingerprintedExternalDependency(ExternalDependency(fileName: path), fingerprint))
        case .identifierNode:
          guard record.fields.count == 0,
                case .blob(let identifierBlob) = record.payload
          else {
            throw ReadError.malformedIdentifierRecord
          }
          identifiers.append(String(decoding: identifierBlob, as: UTF8.self))
        }
      }
    }

    guard var visitor = Visitor(info) else {
      return nil
    }
    try Bitcode.read(bytes: data, using: &visitor)
    guard let major = visitor.majorVersion,
          let minor = visitor.minorVersion,
          visitor.compilerVersionString != nil
    else {
      throw ReadError.malformedMetadataRecord
    }
    let readVersion = Version(Int(major), Int(minor), 0)
    guard readVersion == Self.serializedGraphVersion
    else {
      throw ReadError.mismatchedSerializedGraphVersion(
        expected: Self.serializedGraphVersion, read: readVersion)
    }
    let graph = visitor.finalizeGraph()
    info.reporter?.report("Read dependency graph", path)
    return graph
  }
}

extension ModuleDependencyGraph {
  /// Attempts to serialize this dependency graph and write its contents
  /// to the given file path.
  ///
  /// Should serialization fail, the driver must emit an error *and* moreover
  /// the build record should reflect that the incremental build failed. This
  /// prevents bogus priors from being picked up the next time the build is run.
  /// It's better for us to just redo the incremental build than wind up with
  /// corrupted dependency state.
  ///
  /// - Parameters:
  ///   - path: The location to write the data for this file.
  ///   - fileSystem: The file system for this location.
  ///   - compilerVersion: A string containing version information for the
  ///                      driver used to create this file.
  ///   - mockSerializedGraphVersion: Overrides the standard version for testing
  /// - Returns: true if had error
  @_spi(Testing) public func write(
    to path: VirtualPath,
    on fileSystem: FileSystem,
    compilerVersion: String,
    mockSerializedGraphVersion: Version? = nil
  ) throws {
    let data = ModuleDependencyGraph.Serializer.serialize(
      self, compilerVersion,
      mockSerializedGraphVersion ?? Self.serializedGraphVersion)

    do {
      try fileSystem.writeFileContents(path,
                                       bytes: data,
                                       atomically: true)
    } catch {
      throw IncrementalCompilationState.WriteDependencyGraphError.couldNotWrite(
        path: path, error: error)
    }
  }

  fileprivate final class Serializer {
    let compilerVersion: String
    let serializedGraphVersion: Version
    let stream = BitstreamWriter()
    private var abbreviations = [RecordID: Bitstream.AbbreviationID]()
    private var identifiersToWrite = [String]()
    private var identifierIDs = [String: Int]()
    private var lastIdentifierID: Int = 1
    fileprivate private(set) var nodeIDs = [Node: Int]()
    private var lastNodeID: Int = 0

    private init(compilerVersion: String,
                 serializedGraphVersion: Version) {
      self.compilerVersion = compilerVersion
      self.serializedGraphVersion = serializedGraphVersion
    }

    private func emitSignature() {
      for c in ModuleDependencyGraph.signature {
        self.stream.writeASCII(c)
      }
    }

    private func emitBlockID(_ ID: Bitstream.BlockID, _ name: String) {
      self.stream.writeRecord(Bitstream.BlockInfoCode.setBID) {
        $0.append(ID)
      }

      // Emit the block name if present.
      guard !name.isEmpty else {
        return
      }

      self.stream.writeRecord(Bitstream.BlockInfoCode.blockName) { buffer in
        buffer.append(name)
      }
    }

    private func emitRecordID(_ id: RecordID) {
      self.stream.writeRecord(Bitstream.BlockInfoCode.setRecordName) {
        $0.append(id)
        $0.append(id.humanReadableName)
      }
    }

    private func writeBlockInfoBlock() {
      self.stream.writeBlockInfoBlock {
        self.emitBlockID(.firstApplicationID, "RECORD_BLOCK")
        self.emitRecordID(.metadata)
        self.emitRecordID(.moduleDepGraphNode)
        self.emitRecordID(.useIDNode)
        self.emitRecordID(.externalDepNode)
        self.emitRecordID(.identifierNode)
      }
    }

    private func writeMetadata() {
      self.stream.writeRecord(self.abbreviations[.metadata]!, {
        $0.append(RecordID.metadata)
        $0.append(serializedGraphVersion.majorForWriting)
        $0.append(serializedGraphVersion.minorForWriting)
      },
      blob: self.compilerVersion)
    }

    private func addIdentifier(_ str: String) {
      guard !str.isEmpty && self.identifierIDs[str] == nil else {
        return
      }

      defer { self.lastIdentifierID += 1 }
      self.identifierIDs[str] = self.lastIdentifierID
      self.identifiersToWrite.append(str)
    }

    private func lookupIdentifierCode(for string: String) -> UInt32 {
      guard !string.isEmpty else {
        return 0
      }

      return UInt32(self.identifierIDs[string]!)
    }

    private func cacheNodeID(for node: Node) {
      defer { self.lastNodeID += 1 }
      nodeIDs[node] = self.lastNodeID
    }

    private func populateCaches(from graph: ModuleDependencyGraph) {
      graph.nodeFinder.forEachNode { node in
        self.cacheNodeID(for: node)

        if let dependencySourceFileName = node.dependencySource?.file.name {
          self.addIdentifier(dependencySourceFileName)
        }
        if let context = node.key.designator.context {
          self.addIdentifier(context)
        }
        if let name = node.key.designator.name {
          self.addIdentifier(name)
        }
      }

      for key in graph.nodeFinder.usesByDef.keys {
        if let context = key.designator.context {
          self.addIdentifier(context)
        }
        if let name = key.designator.name {
          self.addIdentifier(name)
        }
      }

      for edF in graph.fingerprintedExternalDependencies {
        self.addIdentifier(edF.externalDependency.fileName)
      }

      for str in self.identifiersToWrite {
        self.stream.writeRecord(self.abbreviations[.identifierNode]!, {
          $0.append(RecordID.identifierNode)
        }, blob: str)
      }
    }

    private func registerAbbreviations() {
      self.abbreviate(.metadata, [
        .literal(RecordID.metadata.rawValue),
        // Major version
        .fixed(bitWidth: 16),
        // Minor version
        .fixed(bitWidth: 16),
        // Frontend version
        .blob,
      ])
      self.abbreviate(.moduleDepGraphNode, [
        .literal(RecordID.moduleDepGraphNode.rawValue),
        // dependency kind discriminator
        .fixed(bitWidth: 3),
        // dependency decl aspect discriminator
        .fixed(bitWidth: 1),
        // dependency context
        .vbr(chunkBitWidth: 13),
        // dependency name
        .vbr(chunkBitWidth: 13),
        // swiftdeps?
        .fixed(bitWidth: 1),
        // swiftdeps path
        .vbr(chunkBitWidth: 13),
        // fingerprint?
        .fixed(bitWidth: 1),
        // fingerprint bytes
        .blob,
      ])
      self.abbreviate(.dependsOnNode, [
        .literal(RecordID.dependsOnNode.rawValue),
        // dependency kind discriminator
        .fixed(bitWidth: 3),
        // dependency decl aspect discriminator
        .fixed(bitWidth: 1),
        // dependency context
        .vbr(chunkBitWidth: 13),
        // dependency name
        .vbr(chunkBitWidth: 13),
      ])

      self.abbreviate(.useIDNode, [
        .literal(RecordID.useIDNode.rawValue),
        // node ID
        .vbr(chunkBitWidth: 13),
      ])
      self.abbreviate(.externalDepNode, [
        .literal(RecordID.externalDepNode.rawValue),
        // path ID
        .vbr(chunkBitWidth: 13),
        // fingerprint?
        .fixed(bitWidth: 1),
        // fingerprint bytes
        .blob
      ])
      self.abbreviate(.identifierNode, [
        .literal(RecordID.identifierNode.rawValue),
        // identifier data
        .blob
      ])
    }

    private func abbreviate(
      _ record: RecordID,
      _ operands: [Bitstream.Abbreviation.Operand]
    ) {
      self.abbreviations[record]
        = self.stream.defineAbbreviation(Bitstream.Abbreviation(operands))
    }

    public static func serialize(
      _ graph: ModuleDependencyGraph,
      _ compilerVersion: String,
      _ serializedGraphVersion: Version
    ) -> ByteString {
      let serializer = Serializer(
        compilerVersion: compilerVersion,
        serializedGraphVersion: serializedGraphVersion)
      serializer.emitSignature()
      serializer.writeBlockInfoBlock()

      serializer.stream.withSubBlock(.firstApplicationID, abbreviationBitWidth: 8) {
        serializer.registerAbbreviations()

        serializer.writeMetadata()

        serializer.populateCaches(from: graph)

        graph.nodeFinder.forEachNode { node in
          serializer.stream.writeRecord(serializer.abbreviations[.moduleDepGraphNode]!, {
            $0.append(RecordID.moduleDepGraphNode)
            $0.append(node.key.designator.code)
            $0.append(node.key.aspect.code)
            $0.append(serializer.lookupIdentifierCode(
                        for: node.key.designator.context ?? ""))
            $0.append(serializer.lookupIdentifierCode(
                        for: node.key.designator.name ?? ""))
            $0.append((node.dependencySource != nil) ? UInt32(1) : UInt32(0))
            $0.append(serializer.lookupIdentifierCode(
                        for: node.dependencySource?.file.name ?? ""))
            $0.append((node.fingerprint != nil) ? UInt32(1) : UInt32(0))
          }, blob: node.fingerprint ?? "")
        }

        for key in graph.nodeFinder.usesByDef.keys {
          serializer.stream.writeRecord(serializer.abbreviations[.dependsOnNode]!) {
            $0.append(RecordID.dependsOnNode)
            $0.append(key.designator.code)
            $0.append(key.aspect.code)
            $0.append(serializer.lookupIdentifierCode(
                        for: key.designator.context ?? ""))
            $0.append(serializer.lookupIdentifierCode(
                        for: key.designator.name ?? ""))
          }
          for use in graph.nodeFinder.usesByDef[key, default: []] {
            guard let useID = serializer.nodeIDs[use] else {
              fatalError("Node ID was not registered! \(use)")
            }

            serializer.stream.writeRecord(serializer.abbreviations[.useIDNode]!) {
              $0.append(RecordID.useIDNode)
              $0.append(UInt32(useID))
            }
          }
        }
        for fingerprintedExternalDependency in graph.fingerprintedExternalDependencies {
          serializer.stream.writeRecord(serializer.abbreviations[.externalDepNode]!, {
            $0.append(RecordID.externalDepNode)
            $0.append(serializer.lookupIdentifierCode(
                        for: fingerprintedExternalDependency.externalDependency.fileName))
            $0.append((fingerprintedExternalDependency.fingerprint != nil) ? UInt32(1) : UInt32(0))
          }, 
          blob: (fingerprintedExternalDependency.fingerprint ?? ""))
        }
      }
      return ByteString(serializer.stream.data)
    }
  }
}

fileprivate extension DependencyKey.DeclAspect {
  init?(_ c: UInt64) {
    switch c {
    case 0:
      self = .interface
    case 1:
      self = .implementation
    default:
      return nil
    }
  }

  var code: UInt32 {
    switch self {
    case .interface:
      return 0
    case .implementation:
      return 1
    }
  }
}

fileprivate extension DependencyKey.Designator {
  init(kindCode: UInt64, context: String, name: String, fileSystem: FileSystem) throws {
    func mustBeEmpty(_ s: String) throws {
      guard s.isEmpty else {
        throw ModuleDependencyGraph.ReadError.bogusNameOrContext
      }
    }

    switch kindCode {
    case 0:
      try mustBeEmpty(context)
      self = .topLevel(name: name)
    case 1:
      try mustBeEmpty(name)
      self = .nominal(context: context)
    case 2:
      try mustBeEmpty(name)
      self = .potentialMember(context: context)
    case 3:
      self = .member(context: context, name: name)
    case 4:
      try mustBeEmpty(context)
      self = .dynamicLookup(name: name)
    case 5:
      try mustBeEmpty(context)
      self = .externalDepend(ExternalDependency(fileName: name))
    case 6:
      try mustBeEmpty(context)
      self = .sourceFileProvide(name: name)
    default: throw ModuleDependencyGraph.ReadError.unknownKind
    }
  }

  var code: UInt32 {
    switch self {
    case .topLevel(name: _):
      return 0
    case .nominal(context: _):
      return 1
    case .potentialMember(context: _):
      return 2
    case .member(context: _, name: _):
      return 3
    case .dynamicLookup(name: _):
      return 4
    case .externalDepend(_):
      return 5
    case .sourceFileProvide(name: _):
      return 6
    }
  }
}

// MARK: - Checking Serialization

extension ModuleDependencyGraph {
  func matches(_ other: ModuleDependencyGraph) -> Bool {
    guard nodeFinder.matches(other.nodeFinder),
          fingerprintedExternalDependencies.matches(other.fingerprintedExternalDependencies)
    else {
      return false
    }
    return true
  }
}

extension Set where Element == ModuleDependencyGraph.Node {
  fileprivate func matches(_ other: Self) -> Bool {
    self == other
  }
}

extension Set where Element == FingerprintedExternalDependency {
  fileprivate func matches(_ other: Self) -> Bool {
    self == other
  }
}

fileprivate extension Version {
  var majorForWriting: UInt32 {
    let r = UInt32(Int64(major))
    assert(Int(r) == Int(major))
    return r
  }
  var minorForWriting: UInt32 {
    let r = UInt32(Int64(minor))
    assert(Int(r) == Int(minor))
    return r
  }
}
