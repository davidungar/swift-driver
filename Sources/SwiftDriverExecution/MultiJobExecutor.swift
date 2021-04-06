//===------- MultiJobExecutor.swift - LLBuild-powered job executor --------===//
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

import TSCBasic
import enum TSCUtility.Diagnostics

import Foundation
import Dispatch
import SwiftDriver

// We either import the llbuildSwift shared library or the llbuild framework.
#if canImport(llbuildSwift)
@_implementationOnly import llbuildSwift
@_implementationOnly import llbuild
#else
@_implementationOnly import llbuild
#endif


public final class MultiJobExecutor {

  /// The context required during job execution.
  /// Must be a class because the producer map can grow as  jobs are added.
  class Context {

    /// This contains mapping from an output to the index(in the jobs array) of the job that produces that output.
    /// Can grow dynamically as  jobs are added.
    var producerMap: [VirtualPath.Handle: Int] = [:]

    /// All the jobs being executed.
    var jobs: [Job] = []

    /// The indices into `jobs` for the primary jobs; those that must be run before the full set of
    /// secondaries can be determined. Basically compilations.
    let primaryIndices: Range<Int>

    /// The indices into `jobs` of the jobs that must run *after* all compilations.
    let postCompileIndices: Range<Int>

    /// If non-null, the driver is performing an incremental compilation.
    let incrementalCompilationState: IncrementalCompilationState?

    /// The resolver for argument template.
    let argsResolver: ArgsResolver

    /// The environment variables.
    let env: [String: String]

    /// The file system.
    let fileSystem: TSCBasic.FileSystem

    /// The job executor delegate.
    let executorDelegate: JobExecutionDelegate

    /// Queue for executor delegate.
    let delegateQueue: DispatchQueue = DispatchQueue(label: "org.swift.driver.job-executor-delegate")

    /// Operation queue for executing tasks in parallel.
    let jobQueue: OperationQueue

    /// The process set to use when launching new processes.
    let processSet: ProcessSet?

    /// If true, always use response files to pass command line arguments.
    let forceResponseFiles: Bool

    /// The last time each input file was modified, recorded at the start of the build.
    public let recordedInputModificationDates: [TypedVirtualPath: Date]

    /// The diagnostics engine to use when reporting errors.
    let diagnosticsEngine: DiagnosticsEngine

    /// The type to use when launching new processes. This mostly serves as an override for testing.
    let processType: ProcessProtocol.Type

    /// If a job fails, the driver needs to stop running jobs.
    private(set) var isBuildCancelled = false

    /// The value of the option
    let continueBuildingAfterErrors: Bool

    /// non-nil if using dynamic batching
    fileprivate var compileServerPool: CompileServerPool?


    init(
      argsResolver: ArgsResolver,
      env: [String: String],
      fileSystem: TSCBasic.FileSystem,
      workload: DriverExecutorWorkload,
      executorDelegate: JobExecutionDelegate,
      jobQueue: OperationQueue,
      processSet: ProcessSet?,
      forceResponseFiles: Bool,
      recordedInputModificationDates: [TypedVirtualPath: Date],
      diagnosticsEngine: DiagnosticsEngine,
      processType: ProcessProtocol.Type = Process.self
    ) {
      (
        jobs: self.jobs,
        producerMap: self.producerMap,
        primaryIndices: self.primaryIndices,
        postCompileIndices: self.postCompileIndices,
        incrementalCompilationState: self.incrementalCompilationState,
        continueBuildingAfterErrors: self.continueBuildingAfterErrors
      ) = Self.fillInJobsAndProducers(workload)

      self.argsResolver = argsResolver
      self.env = env
      self.fileSystem = fileSystem
      self.executorDelegate = executorDelegate
      self.jobQueue = jobQueue
      self.processSet = processSet
      self.forceResponseFiles = forceResponseFiles
      self.recordedInputModificationDates = recordedInputModificationDates
      self.diagnosticsEngine = diagnosticsEngine
      self.processType = processType
      self.compileServerPool = CompileServerPool(
        incrementalCompilationState,
        numServers: jobQueue.maxConcurrentOperationCount,
        env: env,
        argsResolver: argsResolver,
        processSet: processSet,
        forceResponseFiles: forceResponseFiles)
    }

    private static func fillInJobsAndProducers(_ workload: DriverExecutorWorkload
    ) -> (jobs: [Job],
          producerMap: [VirtualPath.Handle: Int],
          primaryIndices: Range<Int>,
          postCompileIndices: Range<Int>,
          incrementalCompilationState: IncrementalCompilationState?,
          continueBuildingAfterErrors: Bool)
    {
      var jobs = [Job]()
      var producerMap = [VirtualPath.Handle: Int]()
      let primaryIndices, postCompileIndices: Range<Int>
      let incrementalCompilationState: IncrementalCompilationState?
      switch workload.kind {
      case let .incremental(ics):
        incrementalCompilationState = ics
        primaryIndices = Self.addJobs(
          ics.mandatoryJobsInOrder,
          to: &jobs,
          producing: &producerMap
        )
        postCompileIndices = Self.addJobs(
          ics.jobsAfterCompiles,
          to: &jobs,
          producing: &producerMap)
      case let .all(nonincrementalJobs):
        incrementalCompilationState = nil
        primaryIndices = Self.addJobs(
          nonincrementalJobs,
          to: &jobs,
          producing: &producerMap)
        postCompileIndices = 0 ..< 0
      }
      return ( jobs: jobs,
               producerMap: producerMap,
               primaryIndices: primaryIndices,
               postCompileIndices: postCompileIndices,
               incrementalCompilationState: incrementalCompilationState,
               continueBuildingAfterErrors: workload.continueBuildingAfterErrors)
    }

    /// Allow for dynamically adding jobs, since some compile  jobs are added dynamically.
    /// Return the indices into `jobs` of the added jobs.
    @discardableResult
    fileprivate static func addJobs(
      _ js: [Job],
      to jobs: inout [Job],
      producing producerMap: inout [VirtualPath.Handle: Int]
    ) -> Range<Int> {
      let initialCount = jobs.count
      for job in js {
        addProducts(of: job, index: jobs.count, knownJobs: jobs, to: &producerMap)
        jobs.append(job)
      }
      return initialCount ..< jobs.count
    }

    ///  Update the producer map when adding a job.
    private static func addProducts(of job: Job,
                                    index: Int,
                                    knownJobs: [Job],
                                    to producerMap: inout [VirtualPath.Handle: Int]
    ) {
      for output in job.outputs {
        if let otherJobIndex = producerMap.updateValue(index, forKey: output.fileHandle) {
          fatalError("multiple producers for output \(output.file): \(job) & \(knownJobs[otherJobIndex])")
        }
        producerMap[output.fileHandle] = index
      }
    }

    fileprivate func getIncrementalJobIndices(finishedJob jobIdx: Int) throws -> Range<Int> {
      if let newJobs = try incrementalCompilationState?
          .collectJobsDiscoveredToBeNeededAfterFinishing(job: jobs[jobIdx]) {
        return Self.addJobs(newJobs, to: &jobs, producing: &producerMap)
      }
      return 0..<0
    }

    fileprivate func cancelBuildIfNeeded(_ result: ProcessResult) {
      switch (result.exitStatus, continueBuildingAfterErrors) {
      case (.terminated(let code), false) where code != EXIT_SUCCESS:
         isBuildCancelled = true
       #if !os(Windows)
       case (.signalled, _):
         isBuildCancelled = true
       #endif
      default:
        break
      }
    }

    fileprivate func reportSkippedJobs() {
      for job in incrementalCompilationState?.skippedJobs ?? [] {
        executorDelegate.jobSkipped(job: job)
      }
    }


  }

  /// The work to be done.
  private let workload: DriverExecutorWorkload

  /// The argument resolver.
  private let argsResolver: ArgsResolver

  /// The job executor delegate.
  private let executorDelegate: JobExecutionDelegate

  /// The number of jobs to run in parallel.
  private let numParallelJobs: Int

  /// The process set to use when launching new processes.
  private let processSet: ProcessSet?

  /// If true, always use response files to pass command line arguments.
  private let forceResponseFiles: Bool

  /// The last time each input file was modified, recorded at the start of the build.
  private let recordedInputModificationDates: [TypedVirtualPath: Date]

  /// The diagnostics engine to use when reporting errors.
  private let diagnosticsEngine: DiagnosticsEngine

  /// The type to use when launching new processes. This mostly serves as an override for testing.
  private let processType: ProcessProtocol.Type

  public init(
    workload: DriverExecutorWorkload,
    resolver: ArgsResolver,
    executorDelegate: JobExecutionDelegate,
    diagnosticsEngine: DiagnosticsEngine,
    numParallelJobs: Int? = nil,
    processSet: ProcessSet? = nil,
    forceResponseFiles: Bool = false,
    recordedInputModificationDates: [TypedVirtualPath: Date] = [:],
    processType: ProcessProtocol.Type = Process.self
  ) {
    self.workload = workload
    self.argsResolver = resolver
    self.executorDelegate = executorDelegate
    self.diagnosticsEngine = diagnosticsEngine
    self.numParallelJobs = numParallelJobs ?? 1
    self.processSet = processSet
    self.forceResponseFiles = forceResponseFiles
    self.recordedInputModificationDates = recordedInputModificationDates
    self.processType = processType
  }

  /// Execute all jobs.
  public func execute(env: [String: String], fileSystem: TSCBasic.FileSystem) throws {
    let context = createContext(env: env, fileSystem: fileSystem)

    let delegate = JobExecutorBuildDelegate(context)
    let engine = LLBuildEngine(delegate: delegate)

    let result = try engine.build(key: ExecuteAllJobsRule.RuleKey())

    context.reportSkippedJobs()

    // Check for any inputs that were modified during the build. Report these
    // as errors so we don't e.g. reuse corrupted incremental build state.
    for (input, recordedModTime) in context.recordedInputModificationDates {
      guard try fileSystem.lastModificationTime(for: input.file) == recordedModTime else {
        let err = Job.InputError.inputUnexpectedlyModified(input)
        context.diagnosticsEngine.emit(err)
        throw err
      }
    }

    // Throw the stub error the build didn't finish successfully.
    if !result.success {
      throw Diagnostics.fatalError
    }
  }

  /// Create the context required during the execution.
  private func createContext(env: [String: String], fileSystem: TSCBasic.FileSystem) -> Context {
    let jobQueue = OperationQueue()
    jobQueue.name = "org.swift.driver.job-execution"
    jobQueue.maxConcurrentOperationCount = numParallelJobs

    return Context(
      argsResolver: argsResolver,
      env: env,
      fileSystem: fileSystem,
      workload: workload,
      executorDelegate: executorDelegate,
      jobQueue: jobQueue,
      processSet: processSet,
      forceResponseFiles: forceResponseFiles,
      recordedInputModificationDates: recordedInputModificationDates,
      diagnosticsEngine: diagnosticsEngine,
      processType: processType
    )
  }
}

struct JobExecutorBuildDelegate: LLBuildEngineDelegate {

  let context: MultiJobExecutor.Context

  init(_ context: MultiJobExecutor.Context) {
    self.context = context
  }

  func lookupRule(rule: String, key: Key) -> Rule {
    switch rule {
    case ExecuteAllJobsRule.ruleName:
      return ExecuteAllJobsRule(context: context)
    case ExecuteAllCompilationJobsRule.ruleName:
      return ExecuteAllCompilationJobsRule(context: context)
    case ExecuteJobRule.ruleName:
      return ExecuteJobRule(key, context: context)
    default:
      fatalError("Unknown rule \(rule)")
    }
  }
}

/// The build value for driver build tasks.
struct DriverBuildValue: LLBuildValue {
  enum Kind: String, Codable {
    case jobExecution
  }

  /// If the build value was a success.
  var success: Bool

  /// The kind of build value.
  var kind: Kind

  static func jobExecution(success: Bool) -> DriverBuildValue {
    return .init(success: success, kind: .jobExecution)
  }
}

/// A rule represents all jobs to finish compiling a module, including mandatory jobs,
/// incremental jobs, and post-compilation jobs.
class ExecuteAllJobsRule: LLBuildRule {
  struct RuleKey: LLBuildKey {
    typealias BuildValue = DriverBuildValue
    typealias BuildRule = ExecuteAllJobsRule
  }
  private let context: MultiJobExecutor.Context

  override class var ruleName: String { "\(ExecuteAllJobsRule.self)" }

  /// True if any of the inputs had any error.
  private var allInputsSucceeded: Bool = true

  /// Input ID for the requested ExecuteAllCompilationJobsRule
  private let allCompilationId = Int.max

  init(context: MultiJobExecutor.Context) {
    self.context = context
    super.init(fileSystem: context.fileSystem)
  }

  override func start(_ engine: LLTaskBuildEngine) {
    // Requests all compilation jobs to be done
    engine.taskNeedsInput(ExecuteAllCompilationJobsRule.RuleKey(), inputID: allCompilationId)
  }

  override func provideValue(_ engine: LLTaskBuildEngine, inputID: Int, value: Value) {
    do {
      let subtaskSuccess = try DriverBuildValue(value).success
      // After all compilation jobs are done, we can schedule post-compilation jobs,
      // including merge module and linking jobs.
      if inputID == allCompilationId && subtaskSuccess {
        context.compileServerPool?.terminateAll();
        schedulePostCompileJobs(engine)
      }
      allInputsSucceeded = allInputsSucceeded && subtaskSuccess
    } catch {
      allInputsSucceeded = false
    }
  }

  /// After all compilation jobs have run, figure which, for instance link, jobs must run
  private func schedulePostCompileJobs(_ engine: LLTaskBuildEngine) {
    for postCompileIndex in context.postCompileIndices {
      let job = context.jobs[postCompileIndex]
      /// If any compile jobs ran, skip the expensive mod-time checks
      if context.primaryIndices.isEmpty,
         let incrementalCompilationState = context.incrementalCompilationState,
         incrementalCompilationState.canSkipPostCompile(job: job) {
        continue
      }
      engine.taskNeedsInput(ExecuteJobRule.RuleKey(index: postCompileIndex),
                            inputID: postCompileIndex)
    }
  }

  override func inputsAvailable(_ engine: LLTaskBuildEngine) {
    engine.taskIsComplete(DriverBuildValue.jobExecution(success: allInputsSucceeded))
  }
}

/// A rule for evaluating all compilation jobs, including mandatory and Incremental
/// compilations.
class ExecuteAllCompilationJobsRule: LLBuildRule {
  struct RuleKey: LLBuildKey {
    typealias BuildValue = DriverBuildValue
    typealias BuildRule = ExecuteAllCompilationJobsRule
  }

  override class var ruleName: String { "\(ExecuteAllCompilationJobsRule.self)" }

  private let context: MultiJobExecutor.Context

  /// True if any of the inputs had any error.
  private var allInputsSucceeded: Bool = true

  init(context: MultiJobExecutor.Context) {
    self.context = context
    super.init(fileSystem: context.fileSystem)
  }

  override func start(_ engine: LLTaskBuildEngine) {
    // We need to request those mandatory jobs to be done first.
    context.primaryIndices.forEach {
      let key = ExecuteJobRule.RuleKey(index: $0)
      engine.taskNeedsInput(key, inputID: $0)
    }
  }

  override func isResultValid(_ priorValue: Value) -> Bool {
    return false
  }

  override func provideValue(_ engine: LLTaskBuildEngine, inputID: Int, value: Value) {
    do {
      let buildSuccess = try DriverBuildValue(value).success
      // For each finished job, ask the incremental build oracle for additional
      // jobs to be scheduled and request them as the additional inputs for this
      // rule.
      if buildSuccess && !context.isBuildCancelled {
        try context.getIncrementalJobIndices(finishedJob: inputID).forEach {
          engine.taskNeedsInput(ExecuteJobRule.RuleKey(index: $0), inputID: $0)
        }
      }
      allInputsSucceeded = allInputsSucceeded && buildSuccess
    } catch {
      allInputsSucceeded = false
    }
  }

  override func inputsAvailable(_ engine: LLTaskBuildEngine) {
    engine.taskIsComplete(DriverBuildValue.jobExecution(success: allInputsSucceeded))
  }
}
/// A rule for a single compiler invocation.
class ExecuteJobRule: LLBuildRule {
  struct RuleKey: LLBuildKey {
    typealias BuildValue = DriverBuildValue
    typealias BuildRule = ExecuteJobRule

    let index: Int
  }

  override class var ruleName: String { "\(ExecuteJobRule.self)" }

  private let key: RuleKey
  private let context: MultiJobExecutor.Context

  /// True if any of the inputs had any error.
  private var allInputsSucceeded: Bool = true

  init(_ key: Key, context: MultiJobExecutor.Context) {
    self.key = RuleKey(key)
    self.context = context
    super.init(fileSystem: context.fileSystem)
  }

  override func start(_ engine: LLTaskBuildEngine) {
    // Request all compilation jobs whose outputs this rule depends on.
    for (inputIndex, inputFile) in self.myJob.inputs.enumerated() {
      guard let index = self.context.producerMap[inputFile.fileHandle] else {
        continue
      }
      engine.taskNeedsInput(ExecuteJobRule.RuleKey(index: index), inputID: inputIndex)
    }
  }

  override func isResultValid(_ priorValue: Value) -> Bool {
    return false
  }

  override func provideValue(_ engine: LLTaskBuildEngine, inputID: Int, value: Value) {
    rememberIfInputSucceeded(engine, value: value)
  }

  /// Called when the build engine thinks all inputs are available in order to run the job.
  override func inputsAvailable(_ engine: LLTaskBuildEngine) {
    guard allInputsSucceeded else {
      return engine.taskIsComplete(DriverBuildValue.jobExecution(success: false))
    }
    // We are ready to schedule this job.
    // llbuild relies on the client-side to handle asynchronous runs, so we should
    // execute the job asynchronously without blocking the callback thread.
    // taskIsComplete can be safely called from another thread. The only restriction
    // is we should call it after inputsAvailable is called.
    context.jobQueue.addOperation {
      self.executeJob(engine)
    }
  }

  private var myJob: Job {
    context.jobs[key.index]
  }

  private func rememberIfInputSucceeded(_ engine: LLTaskBuildEngine, value: Value) {
    do {
      let buildValue = try DriverBuildValue(value)
      allInputsSucceeded = allInputsSucceeded && buildValue.success
    } catch {
      allInputsSucceeded = false
    }
  }

  private func executeJob(_ engine: LLTaskBuildEngine) {
    if context.isBuildCancelled {
      engine.taskIsComplete(DriverBuildValue.jobExecution(success: false))
      return
    }
    let env = context.env.merging(myJob.extraEnvironment, uniquingKeysWith: { $1 })

    let (result, pendingFinish, pid) =
      context.compileServerPool != nil && myJob.kind == .compile
    ? executeCompileServerJob(env: env)
    : executeNonCompileServerJob(env: env)

    let value: DriverBuildValue
    switch result {
    case .success(let processResult):
      let success = processResult.exitStatus == .terminated(code: EXIT_SUCCESS)
      if !success {
        switch processResult.exitStatus {
        case let .terminated(code):
          if !myJob.kind.isCompile || code != EXIT_FAILURE {
            context.diagnosticsEngine.emit(.error_command_failed(kind: myJob.kind, code: code))
          }
  #if !os(Windows)
        case let .signalled(signal):
          // An interrupt of an individual compiler job means it was deliberatly cancelled,
          // most likely by the driver itself. This does not constitute an error.
          if signal != SIGINT {
            context.diagnosticsEngine.emit(.error_command_signalled(kind: myJob.kind, signal: signal))
          }
  #endif
        }
      }
      // Inform the delegate about job finishing.
      context.delegateQueue.sync {
        context.executorDelegate.jobFinished(job: myJob, result: processResult, pid: pid)
      }
      context.cancelBuildIfNeeded(processResult)
      value = .jobExecution(success: success)

    case .failure(let error):
      if error is DiagnosticData {
        context.diagnosticsEngine.emit(error)
      }
      // Only inform finished job if the job has been started, otherwise the build
      // system may complain about malformed output
      if (pendingFinish) {
        context.delegateQueue.sync {
          let result = ProcessResult(
            arguments: [],
            environment: env,
            exitStatus: .terminated(code: EXIT_FAILURE),
            output: Result.success([]),
            stderrOutput: Result.success([])
          )
          context.executorDelegate.jobFinished(job: myJob, result: result, pid: pid)
        }
      }
      value = .jobExecution(success: false)
    }
    engine.taskIsComplete(value)
  }

  private func executeNonCompileServerJob(env: [String: String]
  ) -> (result: Result<ProcessResult, Error>, pendingFinish: Bool, pid: Int) {
    let context = self.context
    let resolver = context.argsResolver
    let job = myJob

    var pendingFinish = false
    var pid = 0
    do {
      let arguments: [String] = try resolver.resolveArgumentList(for: job,
                                                                 forceResponseFiles: context.forceResponseFiles)

      let process = try context.processType.launchProcess(
        arguments: arguments, env: env
      )
      pid = Int(process.processID)

      // Add it to the process set if it's a real process.
      if case let realProcess as TSCBasic.Process = process {
        try context.processSet?.add(realProcess)
      }

      // Inform the delegate.
      context.delegateQueue.sync {
        context.executorDelegate.jobStarted(job: job, arguments: arguments, pid: pid)
      }
      pendingFinish = true

      let result = try process.waitUntilExit()


      return (Result.success(result), pendingFinish, pid)
    } catch {
      return (Result.failure(error), pendingFinish, pid)
    }
  }


  private func executeCompileServerJob(env: [String: String]
  ) -> (result: Result<ProcessResult, Error>, pendingFinish: Bool, pid: Int) {
    precondition(context.compileServerPool != nil)
    let context = self.context
    let resolver = context.argsResolver
    let job = myJob
    let arguments: [String] = try! resolver.resolveArgumentList(for: job,
                                                               forceResponseFiles: context.forceResponseFiles)

    var server = context.compileServerPool!.acquireCompileServer()
    let oldCounts = (server.outputs.0.count, server.outputs.1.count)
    // MyLog.log("<")
    server.writeSourceFileName(job)
    // Inform the delegate.
    let pid = job.phoneyPid
    context.delegateQueue.sync {
      context.executorDelegate.jobStarted(job: job, arguments: arguments, pid: pid)
    }

    server.readCompletion()
    // MyLog.log(">")

    let (currentOutput, currentStdout) = (server.outputs.0.suffix(from: oldCounts.0),
                                          server.outputs.1.suffix(from: oldCounts.1))

    context.compileServerPool!.releaseCompileServer(server)

    let processResult = ProcessResult(arguments: arguments,
                                      environment: env,
                                      exitStatusCode: 0,
                                      output: .success(Array(currentOutput)),
                                      stderrOutput: .success(Array(currentStdout)))


    return (Result.success(processResult), false, pid)
  }
}

extension Job: LLBuildValue { }

private extension TSCBasic.Diagnostic.Message {
  static func error_command_failed(kind: Job.Kind, code: Int32) -> TSCBasic.Diagnostic.Message {
    .error("\(kind.rawValue) command failed with exit code \(code) (use -v to see invocation)")
  }

  static func error_command_signalled(kind: Job.Kind, signal: Int32) -> TSCBasic.Diagnostic.Message {
    .error("\(kind.rawValue) command failed due to signal \(signal) (use -v to see invocation)")
  }
}

fileprivate struct CompilerServer {
  let pid: Int
  let process: TSCBasic.Process
  let sourceFileNameP, completionP, stdoutP, stderrP: Pipe
  var sourceFile: VirtualPath? = nil

  //var buf = Array<UInt8>(repeating: 0, count: 100000)

  var sourceFileNameFD: Int32 { sourceFileNameP.fileHandleForWriting.fileDescriptor}
  var     completionFD: Int32 {     completionP.fileHandleForReading.fileDescriptor}
  var         stdoutFD: Int32 {         stdoutP.fileHandleForReading.fileDescriptor}
  var         stderrFD: Int32 {         stderrP.fileHandleForReading.fileDescriptor}

  init(env: [String: String], job: Job, resolver: ArgsResolver, processSet: ProcessSet?, forceResponseFiles: Bool) {
    do {
      let arguments: [String] = try resolver.resolveArgumentList(for: job,
                                                                 forceResponseFiles: forceResponseFiles)
      let stdoutP = Pipe()
      let stderrP = Pipe()
      let sourceFileNameP = Pipe()
      let completionP = Pipe()

      let process = Process(arguments: arguments, environment: env, outputRedirection: .none)
      self.process = process
      try process.launchCompileServer(
        stdoutP: stdoutP,
        stderrP: stderrP,
        sourceFileNameP: sourceFileNameP,
        completionP: completionP)

      //dmuxxx MyLog.log("launched") //dmuxxx
      self.pid = Int(process.processID)

      try processSet?.add(process)

      self.sourceFileNameP = sourceFileNameP
      self.completionP = completionP
      self.stdoutP = stdoutP
      self.stderrP = stderrP
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

  mutating func writeSourceFileName(_ job: Job) {
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

  mutating func readCompletion() {
    var buf = Array<UInt8>(repeating: 0, count: 1000)
    //dmuxxx MyLog.log("about to read completion of \(sourceFile?.basename ?? "???")", completionFD)
    let rres = withUnsafeMutablePointer(to: &buf) { read(completionFD, $0, 1) }
    //dmuxxx MyLog.log("read completion of \(sourceFile?.basename ?? "???")", completionFD)
    if rres != 1 {
      //dmuxxx MyLog.log("bad read of \(sourceFile?.basename ?? "???")", rres, errno, to: &stderrStream); stderrStream.flush()
    }
  }

  var outputs: ([UInt8], [UInt8]) {
    return try! (process.stdout.result.get(), process.stderr.result.get())
  }
  func terminate() {
    close(sourceFileNameFD)
    // MyLog.log("*")
  }
}

extension TSCBasic.Process {


  fileprivate func launchCompileServer(
    stdoutP: Pipe,
    stderrP: Pipe,
    sourceFileNameP: Pipe,
    completionP: Pipe
  ) throws {
    precondition(arguments.count > 0 && !arguments[0].isEmpty, "Need at least one argument to launch the process.")
    precondition(!launched, "It is not allowed to launch the same process object again.")
    precondition(Set(
      [stdoutP, stderrP, sourceFileNameP, completionP]
        .flatMap {[$0.fileHandleForReading.fileDescriptor, $0.fileHandleForWriting.fileDescriptor]}
      )
      .count == 8)

    // Set the launch bool to true.
    launched = true

    // Print the arguments if we are verbose.
    if self.verbose {
      stdoutStream <<< arguments.map({ $0.spm_shellEscaped() }).joined(separator: " ") <<< "\n"
                                                                                            stdoutStream.flush()
    }

    // Look for executable.
    let executable = arguments[0]
    guard let executablePath = Process.findExecutable(executable) else {
      throw Process.Error.missingExecutableProgram(program: executable)
    }

#if os(Windows)
   fatalError()
#else
    // Initialize the spawn attributes.
#if canImport(Darwin) || os(Android)
    var attributes: posix_spawnattr_t? = nil
#else
    var attributes = posix_spawnattr_t()
#endif
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }

    // Unmask all signals.
    var noSignals = sigset_t()
    sigemptyset(&noSignals)
    posix_spawnattr_setsigmask(&attributes, &noSignals)

    // Reset all signals to default behavior.
#if os(macOS)
    var mostSignals = sigset_t()
    sigfillset(&mostSignals)
    sigdelset(&mostSignals, SIGKILL)
    sigdelset(&mostSignals, SIGSTOP)
    posix_spawnattr_setsigdefault(&attributes, &mostSignals)
#else
    // On Linux, this can only be used to reset signals that are legal to
    // modify, so we have to take care about the set we use.
    var mostSignals = sigset_t()
    sigemptyset(&mostSignals)
    for i in 1 ..< SIGSYS {
      if i == SIGKILL || i == SIGSTOP {
        continue
      }
      sigaddset(&mostSignals, i)
    }
    posix_spawnattr_setsigdefault(&attributes, &mostSignals)
#endif

    // Set the attribute flags.
    var flags = POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
      // Establish a separate process group.
    flags |= POSIX_SPAWN_SETPGROUP
    posix_spawnattr_setpgroup(&attributes, 0)

    posix_spawnattr_setflags(&attributes, Int16(flags))

    // Setup the file actions.
#if canImport(Darwin) || os(Android)
    var fileActions: posix_spawn_file_actions_t? = nil
#else
    var fileActions = posix_spawn_file_actions_t()
#endif
    posix_spawn_file_actions_init(&fileActions)
    defer { posix_spawn_file_actions_destroy(&fileActions) }

    if let workingDirectory = workingDirectory?.pathString {
#if os(macOS)
      // The only way to set a workingDirectory is using an availability-gated initializer, so we don't need
      // to handle the case where the posix_spawn_file_actions_addchdir_np method is unavailable. This check only
      // exists here to make the compiler happy.
      if #available(macOS 10.15, *) {
        posix_spawn_file_actions_addchdir_np(&fileActions, workingDirectory)
      }
#elseif os(Linux)
      guard SPM_posix_spawn_file_actions_addchdir_np_supported() else {
        throw Process.Error.workingDirectoryNotSupported
      }

      SPM_posix_spawn_file_actions_addchdir_np(&fileActions, workingDirectory)
#else
      throw Process.Error.workingDirectoryNotSupported
#endif
    }

    // Workaround for https://sourceware.org/git/gitweb.cgi?p=glibc.git;h=89e435f3559c53084498e9baad22172b64429362
    // Change allowing for newer version of glibc
    guard let devNull = strdup("/dev/null") else {
      throw SystemError.posix_spawn(0, arguments)
    }
    defer { free(devNull) }
    // Open /dev/null as stdin.
    do {
      let r = posix_spawn_file_actions_addopen(&fileActions, 0, devNull, O_RDONLY, 0)
      if r != 0 {fatalError()}
    }


    //dmuxxx MyLog.log("launch", arguments.joined(separator: " "))



    // Open the write end of the pipe.
    posix_spawn_file_actions_adddup2(&fileActions, stdoutP.fileHandleForWriting.fileDescriptor, 1)

    // Close the other ends of the pipe.
    posix_spawn_file_actions_addclose(&fileActions, stdoutP.fileHandleForWriting.fileDescriptor)
    posix_spawn_file_actions_addclose(&fileActions, stdoutP.fileHandleForReading.fileDescriptor)


    // If no redirect was requested, open the pipe for stderr.
    posix_spawn_file_actions_adddup2(&fileActions, stderrP.fileHandleForWriting.fileDescriptor, 2)

    // Close the other ends of the pipe.
    posix_spawn_file_actions_addclose(&fileActions, stderrP.fileHandleForReading.fileDescriptor)
    posix_spawn_file_actions_addclose(&fileActions, stderrP.fileHandleForWriting.fileDescriptor)


    func closeIfOK(_ f: Int32) {
      if ![0, 1, 2, 3, 4, 5].contains(f) {
        if posix_spawn_file_actions_addclose(&fileActions, f) != 0 {fatalError()}
      }
    }
    let fdsToCloseThere = [
      sourceFileNameP.fileHandleForWriting,
      completionP.fileHandleForReading]
      .map {$0.fileDescriptor}
    fdsToCloseThere.forEach(closeIfOK)

    let fdsToDup = [
      (sourceFileNameP.fileHandleForReading, Int32(3)),
      (completionP.fileHandleForWriting, Int32(4))]
      .map {($0.0.fileDescriptor, $0.1)}

    fdsToDup .forEach { fdHere, fdThere in
      let r = posix_spawn_file_actions_adddup2(&fileActions, fdHere, fdThere)
      if r != 0 {fatalError()}
    }
    do {
      let r = posix_spawn_file_actions_adddup2(&fileActions, 2, 5)
      if r != 0 {fatalError()}
    }


    let argv = CStringArray(arguments + ["-no-color-diagnostics"])
    let env = CStringArray(environment.map({ "\($0.0)=\($0.1)" }))
    let rv = posix_spawnp(&processID, argv.cArray[0]!, &fileActions, &attributes, argv.cArray, env.cArray)

    guard rv == 0 else {
      throw SystemError.posix_spawn(rv, arguments)
    }
    let outputClosures = outputRedirection.outputClosures

    // Close the write end of the output pipe.
    guard close(stdoutP.fileHandleForWriting.fileDescriptor) == 0 else {fatalError()}

    // Create a thread and start reading the output on it.
    var thread = Thread { [weak self] in
      if let readResult = self?.readOutput(onFD: stdoutP.fileHandleForReading.fileDescriptor,
                                           outputClosure: outputClosures?.stdoutClosure) {
            self?.stdout.result = readResult
        }
    }
    thread.start()
    self.stdout.thread = thread

    // Only schedule a thread for stderr if no redirect was requested.
    // Close the write end of the stderr pipe.
    guard close(stderrP.fileHandleForWriting.fileDescriptor) == 0 else {fatalError()}

    // Create a thread and start reading the stderr output on it.
    thread = Thread { [weak self] in
      if let readResult = self?.readOutput(onFD: stderrP.fileHandleForWriting.fileDescriptor, outputClosure: outputClosures?.stderrClosure) {
        self?.stderr.result = readResult
      }
      thread.start()
      self?.stderr.thread = thread
    }
    fdsToDup.forEach { close($0.0) }
#endif // POSIX implementation
  }
}

struct MyLog {
  static var s = try! ThreadSafeOutputByteStream(LocalFileOutputByteStream(
    AbsolutePath("/tmp/y"),
    closeOnDeinit: false))

  static func log(_ msgs: String...) {log(msgs)}
  static func log(_ msgs: [String]) {
    print(msgs.joined(separator: " "), to: &s)
    s.flush()
  }
}

/// Compiler servers
fileprivate struct CompileServerPool {
  private let compileServerQueue: DispatchQueue = DispatchQueue(label: "com.apple.swift-driver.compile-servers", qos: .userInteractive)
  private var freeCompileServers: [CompilerServer]

  init?(_ incrementalCompilerState: IncrementalCompilationState?,
       numServers: Int,
       env: [String: String],
       argsResolver: ArgsResolver,
       processSet: ProcessSet?,
       forceResponseFiles: Bool
      ) {
    guard let compileServerJob = incrementalCompilerState?.compileServerJob
    else {
      return nil
    }

    do {
      var newCompilerServer: CompilerServer {
        CompilerServer(env: env,
                       job: compileServerJob,
                       resolver: argsResolver,
                       processSet: processSet,
                       forceResponseFiles: forceResponseFiles)
      }


      self.freeCompileServers = (0 ..< numServers).reduce(into: {
        var a = [CompilerServer]()
        a.reserveCapacity(numServers)
        return a
      }()) {
        servers, _ in servers.append(newCompilerServer)
      }
    }
    assert( Set(freeCompileServers.map {$0.sourceFileNameFD}).count == freeCompileServers.count)
  }

  mutating fileprivate func acquireCompileServer() -> CompilerServer {
    compileServerQueue.sync {
      if freeCompileServers.isEmpty {
        abort() // launchCompileServer first N times, then what??
      }
      return freeCompileServers.removeLast()
    }
  }
  mutating fileprivate func releaseCompileServer(_ cs: CompilerServer) {
    compileServerQueue.sync {
      freeCompileServers.append(cs)
    }
  }
  mutating fileprivate func terminateAll() {
    compileServerQueue.sync {
      freeCompileServers.forEach {$0.terminate()}
    }
  }
}
