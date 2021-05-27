//===--------------- IncrementalCompilationTests.swift - Swift Testing ----===//
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
import XCTest
import TSCBasic

@_spi(Testing) import SwiftDriver
import SwiftOptions
import TestUtilities

// MARK: - Instance variables and initialization
final class IncrementalCompilationTests: XCTestCase {

  var tempDir: AbsolutePath = AbsolutePath("/tmp")

  var derivedDataDir: AbsolutePath {
    tempDir.appending(component: "derivedData")
  }

  let module = "theModule"
  var OFM: AbsolutePath {
    tempDir.appending(component: "OFM.json")
  }
  let baseNamesAndContents = [
    "main": "let foo = 1",
    "other": "let bar = foo"
  ]
  func inputPath(basename: String) -> AbsolutePath {
    tempDir.appending(component: basename + ".swift")
  }
  var inputPathsAndContents: [(AbsolutePath, String)] {
    baseNamesAndContents.map {
      (inputPath(basename: $0.key), $0.value)
    }
  }
  var derivedDataPath: AbsolutePath {
    tempDir.appending(component: "derivedData")
  }
  var masterSwiftDepsPath: AbsolutePath {
    derivedDataPath.appending(component: "\(module)-master.swiftdeps")
  }
  var autolinkIncrementalExpectations: [String] {
    [
      "Incremental compilation: Queuing Extracting autolink information for module \(module)",
    ]
  }
  var autolinkLifecycleExpectations: [String] {
    [
      "Starting Extracting autolink information for module \(module)",
      "Finished Extracting autolink information for module \(module)",
    ]
  }
  var commonArgs: [String] {
    [
      "swiftc",
      "-module-name", module,
      "-o", derivedDataPath.appending(component: module + ".o").pathString,
      "-output-file-map", OFM.pathString,
      "-driver-show-incremental",
      "-driver-show-job-lifecycle",
      "-enable-batch-mode",
      //        "-v",
      "-save-temps",
      "-incremental",
    ]
    + inputPathsAndContents.map {$0.0.pathString} .sorted()
  }

  override func setUp() {
    self.tempDir = try! withTemporaryDirectory(removeTreeOnDeinit: false) {$0}
    try! localFileSystem.createDirectory(derivedDataPath)
    OutputFileMapCreator.write(module: module,
                               inputPaths: inputPathsAndContents.map {$0.0},
                               derivedData: derivedDataPath,
                               to: OFM)
    for (base, contents) in baseNamesAndContents {
      write(contents, to: base)
    }
  }

  deinit {
    try? localFileSystem.removeFileTree(tempDir)
  }
}

// MARK: - Misc. tests
extension IncrementalCompilationTests {

  func testOptionsParsing() throws {
    let optionPairs: [(
      Option, (IncrementalCompilationState.IncrementalDependencyAndInputSetup) -> Bool
    )] = [
      (.driverAlwaysRebuildDependents, {$0.alwaysRebuildDependents}),
      (.driverShowIncremental, {$0.reporter != nil}),
      (.driverEmitFineGrainedDependencyDotFileAfterEveryImport, {$0.emitDependencyDotFileAfterEveryImport}),
      (.driverVerifyFineGrainedDependencyGraphAfterEveryImport, {$0.verifyDependencyGraphAfterEveryImport}),
      (.enableIncrementalImports, {$0.isCrossModuleIncrementalBuildEnabled}),
      (.disableIncrementalImports, {!$0.isCrossModuleIncrementalBuildEnabled}),
    ]

    for (driverOption, stateOptionFn) in optionPairs {
      try doABuild(
        "initial",
        checkDiagnostics: false,
        extraArguments: [ driverOption.spelling ],
        expectingRemarks: [],
        whenAutolinking: [])

      guard let sdkArgumentsForTesting = try Driver.sdkArgumentsForTesting()
      else {
        throw XCTSkip("Cannot perform this test on this host")
      }
      var driver = try Driver(args: self.commonArgs + [
        driverOption.spelling,
      ] + sdkArgumentsForTesting)
      _ = try driver.planBuild()
      XCTAssertFalse(driver.diagnosticEngine.hasErrors)
      let state = try XCTUnwrap(driver.incrementalCompilationState)
      XCTAssertTrue(stateOptionFn(state.moduleDependencyGraph.info))
    }
  }

  /// Ensure that autolink output file goes with .o directory, to not prevent incremental omission of
  /// autolink job.
  /// Much of the code below is taking from testLinking(), but uses the output file map code here.
  func testAutolinkOutputPath() {
    var env = ProcessEnv.vars
    env["SWIFT_DRIVER_TESTS_ENABLE_EXEC_PATH_FALLBACK"] = "1"
    env["SWIFT_DRIVER_SWIFT_AUTOLINK_EXTRACT_EXEC"] = "/garbage/swift-autolink-extract"
    env["SWIFT_DRIVER_DSYMUTIL_EXEC"] = "/garbage/dsymutil"

    var driver = try! Driver(
      args: commonArgs
        + ["-emit-library", "-target", "x86_64-unknown-linux"],
      env: env)
    let plannedJobs = try! driver.planBuild()
    let autolinkExtractJob = try! XCTUnwrap(
      plannedJobs
        .filter { $0.kind == .autolinkExtract }
        .first)
    let autoOuts = autolinkExtractJob.outputs.filter {$0.type == .autolink}
    XCTAssertEqual(autoOuts.count, 1)
    let autoOut = autoOuts[0]
    let expected = AbsolutePath(derivedDataPath, "\(module).autolink")
    XCTAssertEqual(autoOut.file.absolutePath, expected)
  }
}

// MARK: - Dot file tests
extension IncrementalCompilationTests {
  func testDependencyDotFiles() throws {
    expectNoDotFiles()
    try tryInitial(extraArguments: ["-driver-emit-fine-grained-dependency-dot-file-after-every-import"])
    expect(dotFilesFor: [
      "main.swiftdeps",
      DependencyGraphDotFileWriter.moduleDependencyGraphBasename,
      "other.swiftdeps",
      DependencyGraphDotFileWriter.moduleDependencyGraphBasename,
    ])
  }

  func testDependencyDotFilesCross() throws {
    expectNoDotFiles()
    try tryInitial(extraArguments: [
      "-driver-emit-fine-grained-dependency-dot-file-after-every-import",
    ])
    removeDotFiles()
    try tryTouchingOther(extraArguments: [
      "-driver-emit-fine-grained-dependency-dot-file-after-every-import",
    ])

    expect(dotFilesFor: [
      DependencyGraphDotFileWriter.moduleDependencyGraphBasename,
      "other.swiftdeps",
      DependencyGraphDotFileWriter.moduleDependencyGraphBasename,
    ])
  }

  func expectNoDotFiles() {
    guard localFileSystem.exists(derivedDataDir) else { return }
    try! localFileSystem.getDirectoryContents(derivedDataDir)
      .forEach {derivedFile in
        XCTAssertFalse(derivedFile.hasSuffix("dot"))
      }
  }

  func removeDotFiles() {
    try! localFileSystem.getDirectoryContents(derivedDataDir)
      .filter {$0.hasSuffix(".dot")}
      .map {derivedDataDir.appending(component: $0)}
      .forEach {try! localFileSystem.removeFileTree($0)}
  }

  private func expect(dotFilesFor importedFiles: [String]) {
    let expectedDotFiles = Set(
      importedFiles.enumerated()
      .map { offset, element in "\(element).\(offset).dot" })
    let actualDotFiles = Set(
      try! localFileSystem.getDirectoryContents(derivedDataDir)
      .filter {$0.hasSuffix(".dot")})

    let missingDotFiles = expectedDotFiles.subtracting(actualDotFiles)
      .sortedByDotFileSequenceNumbers()
    let extraDotFiles = actualDotFiles.subtracting(expectedDotFiles)
      .sortedByDotFileSequenceNumbers()

    XCTAssertEqual(missingDotFiles, [])
    XCTAssertEqual(extraDotFiles, [])
  }
}

// MARK: - Post-compile jobs
extension IncrementalCompilationTests {
  /// Ensure that if an output of post-compile job is missing, the job gets rerun.
  func testIncrementalPostCompileJob() throws {
    #if !os(Linux)
    let driver = try XCTUnwrap(tryInitial(checkDiagnostics: true))
    for postCompileOutput in try driver.postCompileOutputs() {
      let absPostCompileOutput = try XCTUnwrap(postCompileOutput.file.absolutePath)
      try localFileSystem.removeFileTree(absPostCompileOutput)
      XCTAssertFalse(localFileSystem.exists(absPostCompileOutput))
      try tryNoChange()
      XCTAssertTrue(localFileSystem.exists(absPostCompileOutput))
    }
    #endif
  }
}
fileprivate extension Driver {
  func postCompileOutputs() throws -> [TypedVirtualPath] {
    try XCTUnwrap(incrementalCompilationState).jobsAfterCompiles.flatMap {$0.outputs}
  }
}

// MARK: - Actual incremental tests
extension IncrementalCompilationTests {

  // FIXME: why does it fail on Linux in CI?
  func testIncrementalDiagnostics() throws {
    #if !os(Linux)
    try testIncremental(checkDiagnostics: true)
    #endif
  }

  func testIncremental() throws {
    try testIncremental(checkDiagnostics: false)
  }

  func testIncremental(checkDiagnostics: Bool) throws {
    try tryInitial(checkDiagnostics: checkDiagnostics)
#if true // sometimes want to skip for debugging
    try tryNoChange(checkDiagnostics: checkDiagnostics)
    try tryTouchingOther(checkDiagnostics: checkDiagnostics)
    try tryTouchingBoth(checkDiagnostics: checkDiagnostics)
#endif
    try tryReplacingMain(checkDiagnostics: checkDiagnostics)
  }

  // FIXME: Expect failure in Linux in CI just as testIncrementalDiagnostics
  func testAlwaysRebuildDependents() throws {
#if !os(Linux)
    try tryInitial(checkDiagnostics: true)
    try tryTouchingMainAlwaysRebuildDependents(checkDiagnostics: true)
#endif
  }


  /// Ensure that the mod date of the input comes back exactly the same via the build-record.
  /// Otherwise the up-to-date calculation in `IncrementalCompilationState` will fail.
  func testBuildRecordDateAccuracy() throws {
    try tryInitial()
    try (1...10).forEach { n in
      try tryNoChange(checkDiagnostics: true)
    }
  }

func testAddingInput() throws {
#if !os(Linux)
  try testAddingInput(basenameWithoutExt: "another", defining: "nameInAnother")
#endif
  }

  func testRemovingInput() throws {
    try testRemovingInput(alsoRemoveFromOutputFileMap: true)
  }

  func testRemovingInputButNotInOutputFileMap() throws {
    try testRemovingInput(alsoRemoveFromOutputFileMap: false)
  }

  func testSwappingInputs() throws {
fatalError()
  }

  fileprivate struct AddingInputGraphs {
    let initial, afterAddition, afterAfterAddition: ModuleDependencyGraph
    var all: [ModuleDependencyGraph] {
      [initial, afterAddition, afterAfterAddition]
    }
    func verify(newInput: String, topLevelName: String) {
      initial.ensureOmits(sourceBasenameWithoutExt: newInput)
      initial.ensureOmits(name: topLevelName)
      XCTAssert(afterAddition.contains(sourceBasenameWithoutExt: newInput))
      XCTAssert(afterAfterAddition.contains(sourceBasenameWithoutExt: newInput))
      XCTAssert(afterAddition.contains(name: topLevelName))
      XCTAssert(afterAfterAddition.contains(name: topLevelName))
   }
  }

  private func testAddingInput(basenameWithoutExt: String, defining topLevelName: String
  ) throws {
    let initial = try tryInitial(checkDiagnostics: true).moduleDependencyGraph()

    write("func \(topLevelName)() {}", to: basenameWithoutExt)
    let newInputsPath = inputPath(basename: basenameWithoutExt)
    OutputFileMapCreator.write(module: module,
                               inputPaths: inputPathsAndContents.map {$0.0} + [newInputsPath],
                               derivedData: derivedDataPath,
                               to: OFM)
    let afterAddition      = try tryAfterAddition(      newInputBasenameWithoutExt: basenameWithoutExt, definingTopLevel: topLevelName)
    let afterAfterAddition = try tryAfterAfterAddition( newInputBasenameWithoutExt: basenameWithoutExt)

    let resultantGraphs = AddingInputGraphs(initial: initial,
                                            afterAddition: afterAddition,
                                            afterAfterAddition: afterAfterAddition)

    resultantGraphs.verify(newInput: basenameWithoutExt, topLevelName: topLevelName)
  }

  private func testRemovingInput(alsoRemoveFromOutputFileMap: Bool) throws {
  #if !os(Linux)
    let newInput = "another"
    let topLevelName = "nameInAnother"
    try testAddingInput(basenameWithoutExt: newInput, defining: topLevelName)
    removeInput(newInput)
    if alsoRemoveFromOutputFileMap {
      OutputFileMapCreator.write(module: module,
                                 inputPaths: inputPathsAndContents.map {$0.0},
                                 derivedData: derivedDataPath,
                                 to: OFM)
    }
    try tryAfterRemoving(      removedBasenameWithoutExt: newInput, defining: topLevelName)
    try tryAfterAfterRemoving( removedBasenameWithoutExt: newInput, defining: topLevelName)
  #endif
  }
}

// MARK: - Incremental test stages
extension IncrementalCompilationTests {
  @discardableResult
  private func tryInitial(checkDiagnostics: Bool = false,
                  extraArguments: [String] = []
  ) throws -> Driver {
    try doABuild(
      "initial",
      checkDiagnostics: checkDiagnostics,
      extraArguments: extraArguments,
      expectingRemarks: [
        // Leave off the part after the colon because it varies on Linux:
        // MacOS: The operation could not be completed. (TSCBasic.FileSystemError error 3.).
        // Linux: The operation couldn’t be completed. (TSCBasic.FileSystemError error 3.)
        "Enabling incremental cross-module building",
        "Incremental compilation: Incremental compilation could not read build record at",
        "Incremental compilation: Disabling incremental build: could not read build record",
        "Incremental compilation: Created dependency graph from swiftdeps files",
        "Found 2 batchable jobs",
        "Forming into 1 batch",
        "Adding {compile: main.swift} to batch 0",
        "Adding {compile: other.swift} to batch 0",
        "Forming batch job from 2 constituents: main.swift, other.swift",
        "Starting Compiling main.swift, other.swift",
        "Finished Compiling main.swift, other.swift",
        "Incremental compilation: Scheduling all post-compile jobs because something was compiled",
        "Starting Linking theModule",
        "Finished Linking theModule",
      ],
      whenAutolinking: autolinkLifecycleExpectations)
  }
  private func tryNoChange(checkDiagnostics: Bool = false,
                   extraArguments: [String] = []
  ) throws {
    try doABuild(
      "no-change",
      checkDiagnostics: checkDiagnostics,
      extraArguments: extraArguments,
      expectingRemarks: [
        "Enabling incremental cross-module building",
        "Incremental compilation: Read dependency graph",
        "Incremental compilation: May skip current input:  {compile: main.o <= main.swift}",
        "Incremental compilation: May skip current input:  {compile: other.o <= other.swift}",
        "Incremental compilation: Skipping input:  {compile: main.o <= main.swift}",
        "Incremental compilation: Skipping input:  {compile: other.o <= other.swift}",
        "Skipped Compiling main.swift",
        "Skipped Compiling other.swift",
        "Incremental compilation: Skipping job: Linking theModule; oldest output is current",
      ],
      whenAutolinking: [])
  }
  private func tryTouchingOther(checkDiagnostics: Bool = false,
                        extraArguments: [String] = []
  ) throws {
    touch("other")
    try doABuild(
      "non-propagating",
      checkDiagnostics: checkDiagnostics,
      extraArguments: extraArguments,
      expectingRemarks: [
        "Enabling incremental cross-module building",
        "Incremental compilation: May skip current input:  {compile: main.o <= main.swift}",
        "Incremental compilation: Scheduing changed input  {compile: other.o <= other.swift}",
        "Incremental compilation: Queuing (initial):  {compile: other.o <= other.swift}",
        "Incremental compilation: not scheduling dependents of other.swift; unknown changes",
        "Incremental compilation: Skipping input:  {compile: main.o <= main.swift}",
        "Incremental compilation: Read dependency graph",
        "Found 1 batchable job",
        "Forming into 1 batch",
        "Adding {compile: other.swift} to batch 0",
        "Forming batch job from 1 constituents: other.swift",
        "Starting Compiling other.swift",
        "Finished Compiling other.swift",
        "Incremental compilation: Scheduling all post-compile jobs because something was compiled",
        "Starting Linking theModule",
        "Finished Linking theModule",
        "Skipped Compiling main.swift",
    ],
    whenAutolinking: autolinkLifecycleExpectations)
  }
  private func tryTouchingBoth(checkDiagnostics: Bool = false,
                       extraArguments: [String] = []
 ) throws {
    touch("main")
    touch("other")
    try doABuild(
      "non-propagating, both touched",
      checkDiagnostics: checkDiagnostics,
      extraArguments: extraArguments,
      expectingRemarks: [
        "Enabling incremental cross-module building",
        "Incremental compilation: Read dependency graph",
        "Incremental compilation: Scheduing changed input  {compile: main.o <= main.swift}",
        "Incremental compilation: Scheduing changed input  {compile: other.o <= other.swift}",
        "Incremental compilation: Queuing (initial):  {compile: main.o <= main.swift}",
        "Incremental compilation: Queuing (initial):  {compile: other.o <= other.swift}",
        "Incremental compilation: not scheduling dependents of main.swift; unknown changes",
        "Incremental compilation: not scheduling dependents of other.swift; unknown changes",
        "Found 2 batchable jobs",
        "Forming into 1 batch",
        "Adding {compile: main.swift} to batch 0",
        "Adding {compile: other.swift} to batch 0",
        "Forming batch job from 2 constituents: main.swift, other.swift",
        "Starting Compiling main.swift, other.swift",
        "Finished Compiling main.swift, other.swift",
        "Incremental compilation: Scheduling all post-compile jobs because something was compiled",
        "Starting Linking theModule",
        "Finished Linking theModule",
    ],
    whenAutolinking: autolinkLifecycleExpectations)
  }

  private func tryReplacingMain(checkDiagnostics: Bool = false,
                        extraArguments: [String] = []
  ) throws {
    replace(contentsOf: "main", with: "let foo = \"hello\"")
    try doABuild(
      "propagating into 2nd wave",
      checkDiagnostics: checkDiagnostics,
      extraArguments: extraArguments,
      expectingRemarks: [
        "Enabling incremental cross-module building",
        "Incremental compilation: Read dependency graph",
        "Incremental compilation: Scheduing changed input  {compile: main.o <= main.swift}",
        "Incremental compilation: May skip current input:  {compile: other.o <= other.swift}",
        "Incremental compilation: Queuing (initial):  {compile: main.o <= main.swift}",
        "Incremental compilation: not scheduling dependents of main.swift; unknown changes",
        "Incremental compilation: Skipping input:  {compile: other.o <= other.swift}",
        "Found 1 batchable job",
        "Forming into 1 batch",
        "Adding {compile: main.swift} to batch 0",
        "Forming batch job from 1 constituents: main.swift",
        "Starting Compiling main.swift",
        "Finished Compiling main.swift",
        "Incremental compilation: Fingerprint changed for interface of source file main.swiftdeps in main.swiftdeps",
        "Incremental compilation: Fingerprint changed for implementation of source file main.swiftdeps in main.swiftdeps",
        "Incremental compilation: Traced: interface of source file main.swiftdeps in main.swift -> interface of top-level name 'foo' in main.swift -> implementation of source file other.swiftdeps in other.swift",
        "Incremental compilation: Queuing because of dependencies discovered later:  {compile: other.o <= other.swift}",
        "Incremental compilation: Scheduling invalidated  {compile: other.o <= other.swift}",
        "Found 1 batchable job",
        "Forming into 1 batch",
        "Adding {compile: other.swift} to batch 0",
        "Forming batch job from 1 constituents: other.swift",
        "Starting Compiling other.swift",
        "Finished Compiling other.swift",
        "Incremental compilation: Scheduling all post-compile jobs because something was compiled",
        "Starting Linking theModule",
        "Finished Linking theModule",
      ],
      whenAutolinking: autolinkLifecycleExpectations)
  }

  private func tryTouchingMainAlwaysRebuildDependents(checkDiagnostics: Bool = false,
                                              extraArguments: [String] = []
  ) throws {
    touch("main")
    let extraArgument = "-driver-always-rebuild-dependents"
    try doABuild(
      "non-propagating but \(extraArgument)",
      checkDiagnostics: checkDiagnostics,
      extraArguments: [extraArgument],
      expectingRemarks: [
        "Enabling incremental cross-module building",
        "Incremental compilation: Read dependency graph",
        "Incremental compilation: May skip current input:  {compile: other.o <= other.swift}",
        "Incremental compilation: Queuing (initial):  {compile: main.o <= main.swift}",
        "Incremental compilation: scheduling dependents of main.swift; -driver-always-rebuild-dependents",
        "Incremental compilation: Traced: interface of top-level name 'foo' in main.swift -> implementation of source file other.swiftdeps in other.swift",
        "Incremental compilation: Found dependent of main.swift:  {compile: other.o <= other.swift}",
        "Incremental compilation: Scheduing changed input  {compile: main.o <= main.swift}",
        "Incremental compilation: Immediately scheduling dependent on main.swift  {compile: other.o <= other.swift}",
        "Incremental compilation: Queuing because of the initial set:  {compile: other.o <= other.swift}",
        "Found 2 batchable jobs",
        "Forming into 1 batch",
        "Adding {compile: main.swift} to batch 0",
        "Adding {compile: other.swift} to batch 0",
        "Forming batch job from 2 constituents: main.swift, other.swift",
        "Incremental compilation: Scheduling all post-compile jobs because something was compiled",
        "Starting Compiling main.swift, other.swift",
        "Finished Compiling main.swift, other.swift",
        "Starting Linking theModule",
        "Finished Linking theModule",
      ],
      whenAutolinking: autolinkLifecycleExpectations)
  }

  private func tryAfterAddition(
    newInputBasenameWithoutExt: String,
    definingTopLevel topLevelName: String
  ) throws -> ModuleDependencyGraph {
    let newInputsPath = inputPath(basename:     newInputBasenameWithoutExt)
    return try doABuild(
      "after addition of \(    newInputBasenameWithoutExt)",
      checkDiagnostics: true,
      extraArguments: [newInputsPath.pathString],
      expectingRemarks: [
        "Incremental compilation: Read dependency graph",
        "Incremental compilation: Enabling incremental cross-module building",
        "Incremental compilation: May skip current input:  {compile: main.o <= main.swift}",
        "Incremental compilation: May skip current input:  {compile: other.o <= other.swift}",
        "Incremental compilation: Scheduling new  {compile: \(    newInputBasenameWithoutExt).o <= \(    newInputBasenameWithoutExt).swift}",
        "Incremental compilation: Has malformed dependency source; will queue  {compile: \(    newInputBasenameWithoutExt).o <= \(    newInputBasenameWithoutExt).swift}",
        "Incremental compilation: Missing an output; will queue  {compile: \(    newInputBasenameWithoutExt).o <= \(    newInputBasenameWithoutExt).swift}",
        "Incremental compilation: Queuing (initial):  {compile: \(    newInputBasenameWithoutExt).o <= \(    newInputBasenameWithoutExt).swift}",
        "Incremental compilation: not scheduling dependents of \(    newInputBasenameWithoutExt).swift: no entry in build record or dependency graph",
        "Incremental compilation: Skipping input:  {compile: main.o <= main.swift}",
        "Incremental compilation: Skipping input:  {compile: other.o <= other.swift}",
        "Found 1 batchable job",
        "Forming into 1 batch",
        "Adding {compile: \(    newInputBasenameWithoutExt).swift} to batch 0",
        "Forming batch job from 1 constituents: \(    newInputBasenameWithoutExt).swift",
        "Starting Compiling \(    newInputBasenameWithoutExt).swift",
        "Finished Compiling \(    newInputBasenameWithoutExt).swift",
        "Incremental compilation: New definition: interface of source file \(    newInputBasenameWithoutExt).swiftdeps in \(    newInputBasenameWithoutExt).swiftdeps",
        "Incremental compilation: New definition: implementation of source file \(    newInputBasenameWithoutExt).swiftdeps in \(    newInputBasenameWithoutExt).swiftdeps",
        "Incremental compilation: New definition: interface of top-level name '\(topLevelName)' in \(    newInputBasenameWithoutExt).swiftdeps",
        "Incremental compilation: New definition: implementation of top-level name '\(topLevelName)' in \(    newInputBasenameWithoutExt).swiftdeps",
        "Incremental compilation: Scheduling all post-compile jobs because something was compiled",
        "Starting Linking theModule",
        "Finished Linking theModule",
        "Skipped Compiling main.swift",
        "Skipped Compiling other.swift",
      ],
      whenAutolinking: autolinkLifecycleExpectations)
      .moduleDependencyGraph()
  }

  private func tryAfterAfterAddition(newInputBasenameWithoutExt: String
  ) throws -> ModuleDependencyGraph {
    let newInputPath = inputPath(basename: newInputBasenameWithoutExt)
    return try doABuild(
      "after after addition of \(newInputBasenameWithoutExt)",
      checkDiagnostics: true,
      extraArguments: [newInputPath.pathString],
      expectingRemarks: [
        "Incremental compilation: Read dependency graph",
        "Incremental compilation: Enabling incremental cross-module building",
        "Incremental compilation: May skip current input:  {compile: main.o <= main.swift}",
        "Incremental compilation: May skip current input:  {compile: other.o <= other.swift}",
        "Incremental compilation: May skip current input:  {compile: \(newInputBasenameWithoutExt).o <= \(newInputBasenameWithoutExt).swift}",
        "Incremental compilation: Skipping input:  {compile: main.o <= main.swift}",
        "Incremental compilation: Skipping input:  {compile: other.o <= other.swift}",
        "Incremental compilation: Skipping input:  {compile: \(newInputBasenameWithoutExt).o <= \(newInputBasenameWithoutExt).swift}",
        "Incremental compilation: Skipping job: Linking theModule; oldest output is current",
        "Skipped Compiling \(newInputBasenameWithoutExt).swift",
        "Skipped Compiling main.swift",
        "Skipped Compiling other.swift",
      ],
      whenAutolinking: autolinkLifecycleExpectations)
      .moduleDependencyGraph()
  }

  private func tryAfterRemoving(
    removedBasenameWithoutExt: String,
    defining topLevelName: String
  ) throws {
    let graph = try doABuild(
      "after removal of \(removedBasenameWithoutExt)",
      checkDiagnostics: true,
      extraArguments: [],
      expectingRemarks: [
        "Incremental compilation: Incremental compilation has been disabled,  because  the following inputs were used in the previous compilation but not in this one: \(removedBasenameWithoutExt).swift",
        "Found 2 batchable jobs",
        "Forming into 1 batch",
        "Adding {compile: main.swift} to batch 0",
        "Adding {compile: other.swift} to batch 0",
        "Forming batch job from 2 constituents: main.swift, other.swift",
        "Starting Compiling main.swift, other.swift",
        "Finished Compiling main.swift, other.swift",
        "Starting Linking theModule",
        "Finished Linking theModule",
      ],
      whenAutolinking: autolinkLifecycleExpectations)
      .moduleDependencyGraph()

    XCTAssertNil(graph)
    #warning("more graph tests")
  }

  private func tryAfterAfterRemoving(
        removedBasenameWithoutExt: String,
    defining topLevelName: String
  ) throws {
    let graph = try doABuild(
      "after after removal of \(removedBasenameWithoutExt)",
      checkDiagnostics: true,
      extraArguments: [],
      expectingRemarks: [
        "Incremental compilation: Read dependency graph",
        "Incremental compilation: Enabling incremental cross-module building",
        "Incremental compilation: May skip current input:  {compile: main.o <= main.swift}",
        "Incremental compilation: May skip current input:  {compile: other.o <= other.swift}",
        "Incremental compilation: Skipping input:  {compile: main.o <= main.swift}",
        "Incremental compilation: Skipping input:  {compile: other.o <= other.swift}",
        "Incremental compilation: Skipping job: Linking theModule; oldest output is current",
        "Skipped Compiling main.swift",
        "Skipped Compiling other.swift",
     ],
      whenAutolinking: autolinkLifecycleExpectations)
      .moduleDependencyGraph()

    graph.verifyGraph()
    graph.ensureOmits(sourceBasenameWithoutExt: removedBasenameWithoutExt)
    graph.ensureOmits(name: topLevelName)  }
}

fileprivate extension Driver {
  func moduleDependencyGraph() throws -> ModuleDependencyGraph {
    do {return try XCTUnwrap(incrementalCompilationState?.moduleDependencyGraph) }
    catch {
      XCTFail("no graph")
      throw error
    }
  }
}

fileprivate extension ModuleDependencyGraph {
  /// A convenience for testing
  var allNodes: [Node] {
    var nodes = [Node]()
    nodeFinder.forEachNode {nodes.append($0)}
    return nodes
  }
  func contains(sourceBasenameWithoutExt target: String) -> Bool {
    allNodes.contains {$0.contains(sourceBasenameWithoutExt: target)}
  }
  func contains(name target: String) -> Bool {
    allNodes.contains {$0.contains(name: target)}
  }
  func ensureOmits(sourceBasenameWithoutExt target: String) {
    nodeFinder.forEachNode { node in
      XCTAssertFalse(node.contains(sourceBasenameWithoutExt: target))
    }
  }
  func ensureOmits(name: String) {
    nodeFinder.forEachNode { node in
      XCTAssertFalse(node.contains(name: name))
    }
  }
}

fileprivate extension ModuleDependencyGraph.Node {
  func contains(sourceBasenameWithoutExt target: String) -> Bool {
    switch key.designator {
    case .sourceFileProvide(name: let name):
      return (try? VirtualPath(path: name))
        .map {$0.basenameWithoutExt == target}
      ?? false
    case .externalDepend(let externalDependency):
      return externalDependency.path.map {
        $0.basenameWithoutExt == target
      }
      ?? false
    case .topLevel, .dynamicLookup, .nominal, .member, .potentialMember:
      return false
    }
  }

  func contains(name target: String) -> Bool {
    switch key.designator {
    case .topLevel(name: let name),
      .dynamicLookup(name: let name):
      return name == target
    case .externalDepend, .sourceFileProvide:
      return false
    case .nominal(context: let context),
         .potentialMember(context: let context):
      return context.range(of: target) != nil
    case .member(context: let context, name: let name):
      return context.range(of: target) != nil || name == target
    }
  }
}

// MARK: - Incremental test perturbation helpers
extension IncrementalCompilationTests {
  private func touch(_ name: String) {
    print("*** touching \(name) ***", to: &stderrStream); stderrStream.flush()
    let (path, contents) = try! XCTUnwrap(inputPathsAndContents.filter {$0.0.pathString.contains(name)}.first)
    try! localFileSystem.writeFileContents(path) { $0 <<< contents }
  }

  private func removeInput(_ name: String) {
    print("*** removing \(name) ***", to: &stderrStream); stderrStream.flush()
    try! localFileSystem.removeFileTree(inputPath(basename: name))
  }

  private func replace(contentsOf name: String, with replacement: String ) {
    print("*** replacing \(name) ***", to: &stderrStream); stderrStream.flush()
    let path = inputPath(basename: name)
    let previousContents = try! localFileSystem.readFileContents(path).cString
    try! localFileSystem.writeFileContents(path) { $0 <<< replacement }
    let newContents = try! localFileSystem.readFileContents(path).cString
    XCTAssert(previousContents != newContents, "\(path.pathString) unchanged after write")
    XCTAssert(replacement == newContents, "\(path.pathString) failed to write")
  }

  private func write(_ contents: String, to basename: String) {
    print("*** writing \(contents) to \(basename)")
    try! localFileSystem.writeFileContents(inputPath(basename: basename)) {
      $0 <<< contents
    }
  }
}

// MARK: - Build helpers
extension IncrementalCompilationTests {
  @discardableResult
  func doABuild(_ message: String,
                checkDiagnostics: Bool,
                extraArguments: [String],
                expectingRemarks texts: [String],
                whenAutolinking: [String]
  ) throws -> Driver {
    try doABuild(
      message,
      checkDiagnostics: checkDiagnostics,
      extraArguments: extraArguments,
      expecting: texts.map {.remark($0)},
      expectingWhenAutolinking: whenAutolinking.map {.remark($0)})
  }

  @discardableResult
  func doABuild(_ message: String,
                checkDiagnostics: Bool,
                extraArguments: [String],
                expecting expectations: [Diagnostic.Message],
                expectingWhenAutolinking autolinkExpectations: [Diagnostic.Message]
  ) throws -> Driver {
    print("*** starting build \(message) ***", to: &stderrStream); stderrStream.flush()

    func doTheCompile(_ driver: inout Driver) {
      let jobs = try! driver.planBuild()
      try? driver.run(jobs: jobs)
    }

    guard let sdkArgumentsForTesting = try Driver.sdkArgumentsForTesting()
    else {
      throw XCTSkip("Cannot perform this test on this host")
    }
    let allArgs = commonArgs + extraArguments + sdkArgumentsForTesting
    if !checkDiagnostics {
      // If not checking, print out the diagnostics
      let diagnosticEngine = DiagnosticsEngine(handlers: [
        {print($0, to: &stderrStream); stderrStream.flush()}
      ])
      var driver = try Driver(args: allArgs, env: ProcessEnv.vars,
                              diagnosticsEngine: diagnosticEngine,
                              fileSystem: localFileSystem)
      doTheCompile(&driver)
      print("", to: &stderrStream); stderrStream.flush()
      return driver
    }
    let driver: Driver = try assertDriverDiagnostics(args: allArgs) {
      driver, verifier in
      verifier.forbidUnexpected(.error, .warning, .note, .remark, .ignored)
      expectations.forEach {verifier.expect($0)}
      if driver.isAutolinkExtractJobNeeded {
        autolinkExpectations.forEach {verifier.expect($0)}
      }
      doTheCompile(&driver)
      return driver
    }
    print("", to: &stderrStream); stderrStream.flush()
    return driver
  }
}
