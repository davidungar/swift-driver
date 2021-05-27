import Foundation
//===--------------- FirstWaveComputer.swift - Incremental --------------===//
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
import TSCBasic

extension IncrementalCompilationState {

  struct FirstWaveComputer {
    let moduleDependencyGraph: ModuleDependencyGraph
    let jobsInPhases: JobsInPhases
    let inputsInvalidatedByExternals: TransitivelyInvalidatedInputSet
    let inputFiles: [TypedVirtualPath]
    let sourceFiles: SourceFiles
    let buildRecordInfo: BuildRecordInfo
    let maybeBuildRecord: BuildRecord?
    let fileSystem: FileSystem
    let showJobLifecycle: Bool
    let alwaysRebuildDependents: Bool
    /// If non-null outputs information for `-driver-show-incremental` for input path
    private let reporter: Reporter?

    @_spi(Testing) public init(
      initialState: IncrementalCompilationState.InitialStateForPlanning,
      jobsInPhases: JobsInPhases,
      driver: Driver,
      reporter: Reporter?
    ) {
      self.moduleDependencyGraph = initialState.graph
      self.jobsInPhases = jobsInPhases
      self.inputsInvalidatedByExternals = initialState.inputsInvalidatedByExternals
      self.inputFiles = driver.inputFiles
      self.sourceFiles = SourceFiles(
        inputFiles: inputFiles,
        buildRecord: initialState.maybeBuildRecord)
      self.buildRecordInfo = initialState.buildRecordInfo
      self.maybeBuildRecord = initialState.maybeBuildRecord
      self.fileSystem = driver.fileSystem
      self.showJobLifecycle = driver.showJobLifecycle
      self.alwaysRebuildDependents = initialState.incrementalOptions.contains(
        .alwaysRebuildDependents)
      self.reporter = reporter
    }

    public func compute(batchJobFormer: inout Driver) throws -> FirstWave {
      let (skippedCompileGroups, mandatoryJobsInOrder) =
        try computeInputsAndGroups(batchJobFormer: &batchJobFormer)
      return FirstWave(
        skippedCompileGroups: skippedCompileGroups,
        mandatoryJobsInOrder: mandatoryJobsInOrder)
    }
  }
}

// MARK: - Preparing the first wave
extension IncrementalCompilationState.FirstWaveComputer {
  /// At this stage the graph will have all external dependencies found in the swiftDeps or in the priors
  /// listed in fingerprintExternalDependencies.
  private func computeInputsAndGroups(batchJobFormer: inout Driver)
  throws -> (skippedCompileGroups: [TypedVirtualPath: CompileJobGroup],
             mandatoryJobsInOrder: [Job])
  {
    precondition(sourceFiles.disappeared.isEmpty, "unimplemented")

    let compileGroups =
      Dictionary(uniqueKeysWithValues:
                  jobsInPhases.compileGroups.map { ($0.primaryInput, $0) })
    guard let buildRecord = maybeBuildRecord else {
      let mandatoryCompileGroupsInOrder = sourceFiles.currentInOrder.compactMap {
        input -> CompileJobGroup? in
        compileGroups[input]
      }

      let mandatoryJobsInOrder = try
        jobsInPhases.beforeCompiles +
        batchJobFormer.formBatchedJobs(
          mandatoryCompileGroupsInOrder.flatMap {$0.allJobs()},
          showJobLifecycle: showJobLifecycle)

      moduleDependencyGraph.phase = .buildingAfterEachCompilation
      return (skippedCompileGroups: [:],
              mandatoryJobsInOrder: mandatoryJobsInOrder)
    }
    moduleDependencyGraph.phase = .updatingAfterCompilation

    let skippedInputs = computeSkippedCompilationInputs(
      inputsInvalidatedByExternals: inputsInvalidatedByExternals,
      moduleDependencyGraph,
      buildRecord)

    let skippedCompileGroups = compileGroups.filter { skippedInputs.contains($0.key) }

    let mandatoryCompileGroupsInOrder = inputFiles.compactMap {
      input -> CompileJobGroup? in
      skippedInputs.contains(input)
        ? nil
        : compileGroups[input]
    }

    let mandatoryJobsInOrder = try
      jobsInPhases.beforeCompiles +
      batchJobFormer.formBatchedJobs(
        mandatoryCompileGroupsInOrder.flatMap {$0.allJobs()},
        showJobLifecycle: showJobLifecycle)

    return (skippedCompileGroups: skippedCompileGroups,
            mandatoryJobsInOrder: mandatoryJobsInOrder)
  }

  // Figure out which compilation inputs are *not* mandatory
  private func computeSkippedCompilationInputs(
    inputsInvalidatedByExternals: TransitivelyInvalidatedInputSet,
    _ moduleDependencyGraph: ModuleDependencyGraph,
    _ buildRecord: BuildRecord
  ) -> Set<TypedVirtualPath> {
    let allGroups = jobsInPhases.compileGroups
    // Input == source file
    let changedInputs = computeChangedInputs(moduleDependencyGraph, buildRecord)

    if let reporter = reporter {
      for input in inputsInvalidatedByExternals {
        reporter.report("Invalidated externally; will queue", input)
      }
    }

    let inputsHavingMalformedDependencySources =
      sourceFiles.currentInOrder.filter { sourceFile in
        !moduleDependencyGraph.containsNodes(forSourceFile: sourceFile)
      }

    if let reporter = reporter {
      for input in inputsHavingMalformedDependencySources {
        reporter.report("Has malformed dependency source; will queue", input)
      }
    }
    let inputsMissingOutputs = allGroups.compactMap {
      $0.outputs.contains { (try? !fileSystem.exists($0.file)) ?? true }
        ? $0.primaryInput
        : nil
    }
    if let reporter = reporter {
      for input in inputsMissingOutputs {
        reporter.report("Missing an output; will queue", input)
      }
    }

    // Combine to obtain the inputs that definitely must be recompiled.
    let definitelyRequiredInputs =
      Set(changedInputs.map({ $0.filePath }) +
            inputsInvalidatedByExternals +
            inputsHavingMalformedDependencySources +
            inputsMissingOutputs)
    if let reporter = reporter {
      for scheduledInput in sortByCommandLineOrder(definitelyRequiredInputs) {
        reporter.report("Queuing (initial):", scheduledInput)
      }
    }

    // Sometimes, inputs run in the first wave that depend on the changed inputs for the
    // first wave, even though they may not require compilation.
    // Any such inputs missed, will be found by the rereading of swiftDeps
    // as each first wave job finished.
    let speculativeInputs = collectInputsToBeSpeculativelyRecompiled(
      changedInputs: changedInputs,
      externalDependents: inputsInvalidatedByExternals,
      inputsMissingOutputs: Set(inputsMissingOutputs),
      moduleDependencyGraph)
      .subtracting(definitelyRequiredInputs)

    if let reporter = reporter {
      for dependent in sortByCommandLineOrder(speculativeInputs) {
        reporter.report("Queuing because of the initial set:", dependent)
      }
    }
    let immediatelyCompiledInputs = definitelyRequiredInputs.union(speculativeInputs)

    let skippedInputs = Set(buildRecordInfo.compilationInputModificationDates.keys)
      .subtracting(immediatelyCompiledInputs)
    if let reporter = reporter {
      for skippedInput in sortByCommandLineOrder(skippedInputs) {
        reporter.report("Skipping input:", skippedInput)
      }
    }
    return skippedInputs
  }

  private func sortByCommandLineOrder(_ inputs: Set<TypedVirtualPath>) -> [TypedVirtualPath] {
    inputFiles.filter (inputs.contains)
   }

  /// Encapsulates information about an input the driver has determined has
  /// changed in a way that requires an incremental rebuild.
  struct ChangedInput {
    /// The path to the input file.
    let filePath: TypedVirtualPath
    /// The status of the input file.
    let status: InputInfo.Status
    /// If `true`, the modification time of this input matches the modification
    /// time recorded from the prior build in the build record.
    let datesMatch: Bool
  }

  // Find the inputs that have changed since last compilation, or were marked as needed a build
  private func computeChangedInputs(
    _ moduleDependencyGraph: ModuleDependencyGraph,
    _ outOfDateBuildRecord: BuildRecord
  ) -> [ChangedInput] {
    jobsInPhases.compileGroups.compactMap { group in
      let input = group.primaryInput
      let modDate = buildRecordInfo.compilationInputModificationDates[input]
        ?? Date.distantFuture
      let inputInfo = outOfDateBuildRecord.inputInfos[input.file]
      let previousCompilationStatus = inputInfo?.status ?? .newlyAdded
      let previousModTime = inputInfo?.previousModTime

      // Because legacy driver reads/writes dates wrt 1970,
      // and because converting time intervals to/from Dates from 1970
      // exceeds Double precision, must not compare dates directly
      var datesMatch: Bool {
        modDate.timeIntervalSince1970 == previousModTime?.timeIntervalSince1970
      }

      switch previousCompilationStatus {
      case .upToDate where datesMatch:
        reporter?.report("May skip current input:", input)
        return nil

      case .upToDate:
        reporter?.report("Scheduing changed input", input)
      case .newlyAdded:
        reporter?.report("Scheduling new", input)
      case .needsCascadingBuild:
        reporter?.report("Scheduling cascading build", input)
      case .needsNonCascadingBuild:
        reporter?.report("Scheduling noncascading build", input)
      }
      return ChangedInput(filePath: input,
                          status: previousCompilationStatus,
                          datesMatch: datesMatch)
    }
  }

  // Returns the cascaded files to compile in the first wave, even though it may not be need.
  // The needs[Non}CascadingBuild stuff was cargo-culted from the legacy driver.
  // TODO: something better, e.g. return nothing here, but process changed dependencySource
  // before the whole frontend job finished.
  private func collectInputsToBeSpeculativelyRecompiled(
    changedInputs: [ChangedInput],
    externalDependents: TransitivelyInvalidatedInputSet,
    inputsMissingOutputs: Set<TypedVirtualPath>,
    _ moduleDependencyGraph: ModuleDependencyGraph
  ) -> Set<TypedVirtualPath> {
    let cascadingChangedInputs = computeCascadingChangedInputs(
      from: changedInputs,
      inputsMissingOutputs: inputsMissingOutputs)

    var inputsToBeCertainlyRecompiled = alwaysRebuildDependents ? externalDependents : TransitivelyInvalidatedInputSet()
    inputsToBeCertainlyRecompiled.formUnion(cascadingChangedInputs)

    return inputsToBeCertainlyRecompiled.reduce(into: Set()) {
      speculativelyRecompiledInputs, certainlyRecompiledInput in
      let speculativeDependents = moduleDependencyGraph.collectInputsInvalidatedBy(input: certainlyRecompiledInput)
      for speculativeDependent in speculativeDependents
      where !inputsToBeCertainlyRecompiled.contains(speculativeDependent) {
        if speculativelyRecompiledInputs.insert(speculativeDependent).inserted {
          reporter?.report(
            "Immediately scheduling dependent on \(certainlyRecompiledInput.file.basename)", speculativeDependent)
        }
      }
    }
  }

  //Collect the files that will be compiled whose dependents should be schedule
  private func computeCascadingChangedInputs(
    from changedInputs: [ChangedInput],
    inputsMissingOutputs: Set<TypedVirtualPath>
  ) -> [TypedVirtualPath] {
    changedInputs.compactMap { changedInput in
      let inputIsUpToDate =
        changedInput.datesMatch && !inputsMissingOutputs.contains(changedInput.filePath)
      let basename = changedInput.filePath.file.basename

      // If we're asked to always rebuild dependents, all we need to do is
      // return inputs whose modification times have changed.
      guard !alwaysRebuildDependents else {
        if inputIsUpToDate {
          reporter?.report(
            "not scheduling dependents of \(basename) despite -driver-always-rebuild-dependents because is up to date")
          return nil
        } else {
          reporter?.report(
            "scheduling dependents of \(basename); -driver-always-rebuild-dependents")
          return changedInput.filePath
        }
      }

      switch changedInput.status {
      case .needsCascadingBuild:
        reporter?.report(
          "scheduling dependents of \(basename); needed cascading build")
        return changedInput.filePath
      case .upToDate:
        reporter?.report(
          "not scheduling dependents of \(basename); unknown changes")
        return nil
      case .newlyAdded:
        reporter?.report(
          "not scheduling dependents of \(basename): no entry in build record or dependency graph")
        return nil
      case .needsNonCascadingBuild:
        reporter?.report(
          "not scheduling dependents of \(basename): does not need cascading build")
        return nil
      }
    }
  }
}
