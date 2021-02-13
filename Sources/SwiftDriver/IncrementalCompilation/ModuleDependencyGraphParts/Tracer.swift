//===----------------------------- Tracer.swift ---------------------------===//
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

extension ModuleDependencyGraph {

/// Trace dependencies through the graph
  struct Tracer {
    typealias Graph = ModuleDependencyGraph

    let startingPoints: [Node]
    let graph: ModuleDependencyGraph

    private(set) var tracedUses: [Node] = []

    /// Record the paths taking so that  -driver-show-incremental can explain why things are recompiled
    /// If tracing dependencies, holds a vector used to hold the current path
    /// def - use/def - use/def - ...
    private var currentPathIfTracing: [Node]?

    private let diagnosticEngine: DiagnosticsEngine
  }
}

// MARK:- Tracing
extension ModuleDependencyGraph.Tracer {

  /// Find all uses of `defs` that have not already been traced.
  /// (If already traced, jobs have already been scheduled.)
  static func collectPreviouslyUntracedNodesUsing<Nodes: Sequence> (
    defNodes: Nodes,
    in graph: ModuleDependencyGraph,
    diagnosticEngine: DiagnosticsEngine
  ) -> Self
  where Nodes.Element == ModuleDependencyGraph.Node
  {
    var tracer = Self(collectingUsesOf: defNodes,
                      in: graph,
                      diagnosticEngine: diagnosticEngine)
    tracer.collectPreviouslyUntracedDependents()
    return tracer
  }

  private init<Nodes: Sequence>(collectingUsesOf defs: Nodes,
               in graph: ModuleDependencyGraph,
               diagnosticEngine: DiagnosticsEngine)
  where Nodes.Element == ModuleDependencyGraph.Node
  {
    self.graph = graph
    // Sort so "Tracing" diagnostics are deterministically ordered
    self.startingPoints = defs.sorted()
    self.currentPathIfTracing = graph.info.reporter != nil ? [] : nil
    self.diagnosticEngine = diagnosticEngine
  }
  
  private mutating func collectPreviouslyUntracedDependents() {
    for n in startingPoints {
      collectNextPreviouslyUntracedDependent(of: n)
    }
  }
  
  private mutating func collectNextPreviouslyUntracedDependent(
    of definition: ModuleDependencyGraph.Node
  ) {
    guard graph.isUntraced(definition) else { return }
    graph.amTracing(definition)
    
    tracedUses.append(definition)
    
    // If this node is merely used, but not defined anywhere, nothing else
    // can possibly depend upon it.
    if definition.isExpat { return }
    
    let pathLengthAfterArrival = traceArrival(at: definition);
    
    // If this use also provides something, follow it
    for use in graph.nodeFinder.orderedUses(of: definition) {
      collectNextPreviouslyUntracedDependent(of: use)
    }
    traceDeparture(pathLengthAfterArrival);
  }


  
  private mutating func traceArrival(at visitedNode: ModuleDependencyGraph.Node
  ) -> Int {
    guard var currentPath = currentPathIfTracing else {
      return 0
    }
    currentPath.append(visitedNode)
    currentPathIfTracing = currentPath

    printPath(currentPath)

    return currentPath.count
  }


  private mutating func traceDeparture(_ pathLengthAfterArrival: Int) {
    guard var currentPath = currentPathIfTracing else { return }
    assert(pathLengthAfterArrival == currentPath.count,
           "Path must be maintained throughout recursive visits.")
    currentPath.removeLast()
    currentPathIfTracing = currentPath
  }


  private func printPath(_ path: [Graph.Node]) {
    guard path.first?.dependencySource != path.last?.dependencySource
    else {
      return
    }
    graph.info.reporter?.report(
      [
        "Traced:",
        path
          .compactMap { node in
            node.dependencySource
              .flatMap {
                graph.inputDependencySourceMap.contains(key: $0)
                  ? "\(node.key) in \(graph.inputDependencySourceMap[$0].file.basename)"
                  : "\(node.key)"
              }

          }
          .joined(separator: " -> ")
      ].joined(separator: " ")
    )
  }
}
