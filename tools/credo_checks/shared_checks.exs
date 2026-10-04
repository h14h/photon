# The Credo checks every Photon app runs, configured after
# docs/otp-design-guide.md (rule numbers in the comments). Each app's
# .credo.exs evaluates this file and adds the checks that need its own
# module lists: which modules are the functional core, which sends and
# sleeps are deliberate, which processes belong to whom.
#
# Returns a list of `{check, params}`.
# Rules about how the system is built (data, functions, processes) apply to
# lib/; tests get the readability and test-convention rules.
lib_only = %{excluded: [~r"/_build/", ~r"/deps/", ~r"(^|/)test/"]}

[
  ## Credo's default checks, kept as they ship

  {Credo.Check.Consistency.ExceptionNames, []},
  {Credo.Check.Consistency.LineEndings, []},
  {Credo.Check.Consistency.ParameterPatternMatching, []},
  {Credo.Check.Consistency.SpaceAroundOperators, []},
  {Credo.Check.Consistency.SpaceInParentheses, []},
  {Credo.Check.Consistency.TabsOrSpaces, []},
  {Credo.Check.Design.AliasUsage,
   [priority: :low, if_nested_deeper_than: 2, if_called_more_often_than: 0]},
  {Credo.Check.Design.TagFIXME, []},
  {Credo.Check.Design.TagTODO, [exit_status: 2]},
  {Credo.Check.Readability.AliasOrder, []},
  {Credo.Check.Readability.FunctionNames, []},
  {Credo.Check.Readability.LargeNumbers, []},
  {Credo.Check.Readability.MaxLineLength, [priority: :low, max_length: 120]},
  {Credo.Check.Readability.ModuleAttributeNames, []},
  {Credo.Check.Readability.ModuleNames, []},
  {Credo.Check.Readability.ParenthesesInCondition, []},
  {Credo.Check.Readability.ParenthesesOnZeroArityDefs, []},
  {Credo.Check.Readability.PipeIntoAnonymousFunctions, []},
  {Credo.Check.Readability.PredicateFunctionNames, []},
  {Credo.Check.Readability.PreferImplicitTry, []},
  {Credo.Check.Readability.RedundantBlankLines, []},
  {Credo.Check.Readability.Semicolons, []},
  {Credo.Check.Readability.SpaceAfterCommas, []},
  {Credo.Check.Readability.StringSigils, []},
  {Credo.Check.Readability.TrailingBlankLine, []},
  {Credo.Check.Readability.TrailingWhiteSpace, []},
  {Credo.Check.Readability.UnnecessaryAliasExpansion, []},
  {Credo.Check.Readability.VariableNames, []},
  {Credo.Check.Readability.WithSingleClause, []},
  {Credo.Check.Refactor.Apply, []},
  {Credo.Check.Refactor.FilterCount, []},
  {Credo.Check.Refactor.FilterFilter, []},
  {Credo.Check.Refactor.LongQuoteBlocks, []},
  {Credo.Check.Refactor.MapJoin, []},
  {Credo.Check.Refactor.MatchInCondition, []},
  {Credo.Check.Refactor.NegatedConditionsInUnless, []},
  {Credo.Check.Refactor.NegatedConditionsWithElse, []},
  {Credo.Check.Refactor.RejectReject, []},
  {Credo.Check.Refactor.UnlessWithElse, []},
  {Credo.Check.Warning.BoolOperationOnSameValues, []},
  {Credo.Check.Warning.Dbg, []},
  {Credo.Check.Warning.ExpensiveEmptyEnumCheck, []},
  {Credo.Check.Warning.IExPry, []},
  {Credo.Check.Warning.IoInspect, []},
  {Credo.Check.Warning.MissedMetadataKeyInLoggerConfig, []},
  {Credo.Check.Warning.OperationOnSameValues, []},
  {Credo.Check.Warning.OperationWithConstantResult, []},
  {Credo.Check.Warning.RaiseInsideRescue, []},
  {Credo.Check.Warning.SpecWithStruct, []},
  {Credo.Check.Warning.StructFieldAmount, []},
  {Credo.Check.Warning.UnsafeExec, []},
  {Credo.Check.Warning.UnusedEnumOperation, []},
  {Credo.Check.Warning.UnusedFileOperation, []},
  {Credo.Check.Warning.UnusedKeywordOperation, []},
  {Credo.Check.Warning.UnusedListOperation, []},
  {Credo.Check.Warning.UnusedMapOperation, []},
  {Credo.Check.Warning.UnusedPathOperation, []},
  {Credo.Check.Warning.UnusedRegexOperation, []},
  {Credo.Check.Warning.UnusedStringOperation, []},
  {Credo.Check.Warning.UnusedTupleOperation, []},
  {Credo.Check.Warning.WrongTestFilename, []},

  ## Built-in checks set to the book

  # 12: wire with config read at runtime, not compile-time attributes or Mix.env.
  {Credo.Check.Warning.ApplicationConfigInModuleAttribute, []},
  {Credo.Check.Warning.MixEnv, [excluded_paths: ["mix.exs"]]},
  # 19: atoms only for a small, known set of names.
  {Credo.Check.Warning.UnsafeToAtom, []},
  # 21: build lists by prepending.
  {Credo.Check.Refactor.AppendSingleItem, [files: lib_only]},
  # 33: a module as big as one job needs. Counts Photon modules only, the
  # ones a `use Boundary` declaration names included.
  {Credo.Check.Refactor.ModuleDependencies,
   [
     max_deps: 20,
     dependency_namespaces: ["PhotonCore", "PhotonNode", "Photon", "PhotonWeb"],
     excluded_paths: ["test/"]
   ]},
  # 35: single-purpose functions.
  {Credo.Check.Refactor.ABCSize, [max_size: 30, files: lib_only]},
  {Credo.Check.Refactor.CyclomaticComplexity, [max_complexity: 8]},
  {Credo.Check.Refactor.FunctionArity, [max_arity: 5, ignore_defp: false]},
  # 38: shape code for composition; a pipeline starts from a value. In lib/,
  # a chain of three or more calls on one value is a pipeline; two-level
  # nesting like `File.rm(path(id))` stays, since a one-step pipe reads
  # worse. Tests nest builders inside assertions on purpose.
  {Credo.Check.Refactor.PipeChainStart, []},
  {Credo.Check.Readability.NestedFunctionCalls, [min_pipeline_length: 3, files: lib_only]},
  # 41 and 66: keep the left margin skinny; decide in function heads; with, not nested case.
  {Credo.Check.Refactor.Nesting, [max_nesting: 2]},
  {Credo.Check.Refactor.CondStatements, []},
  {Credo.Check.Refactor.WithClauses, []},
  {Credo.Check.Refactor.RedundantWithClauseResult, []},
  # 54: every test case says whether it may run concurrently.
  {Credo.Check.Refactor.PassAsyncInTestCases, []},
  # 70: module docs, and specs on every public function in lib/.
  {Credo.Check.Readability.ModuleDoc, []},
  {Credo.Check.Readability.Specs, [files: lib_only]},

  ## Photon's own checks that need no app-specific lists (tools/credo_checks)

  # 14: flat data.
  {PhotonCredo.Check.DeepAccessPath, [max_depth: 2, files: lib_only]},
  # 32, 39, 69: a struct names its shape with @type t.
  {PhotonCredo.Check.StructType, [files: lib_only]},
  # 18: fields that must be given are enforced.
  {PhotonCredo.Check.EnforceKeys, [files: lib_only]},
  # 21: no index access in loops.
  {PhotonCredo.Check.IndexAccessInLoop, [files: lib_only]},
  # 24: iodata, not <> onto an accumulator.
  {PhotonCredo.Check.AccumulatorConcat, [files: lib_only]},
  # 25: small tuples.
  {PhotonCredo.Check.SmallTuples, [files: lib_only]},
  # 56: tests capture logs.
  {PhotonCredo.Check.CaptureTestLogs, []},
  # 63: message formats stay in the server's module.
  {PhotonCredo.Check.MessageOwnership, [files: lib_only]},
  # 82: dynamic children choose a restart strategy.
  {PhotonCredo.Check.DynamicChildRestart, []},
  # 85: only supervisors shut down with :infinity.
  {PhotonCredo.Check.WorkerShutdown, []},
  # 93: bounded concurrency.
  {PhotonCredo.Check.BoundedTaskConcurrency, [files: lib_only]},
  # Exceptions to the rules say why: inline credo:disable comments and
  # @dialyzer attributes, and every .dialyzer_ignore.exs entry.
  {PhotonCredo.Check.SuppressionNeedsReason, []},
  {PhotonCredo.Check.DialyzerIgnoreReasons, []}
]
