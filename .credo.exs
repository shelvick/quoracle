# .credo.exs
%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/"],
        excluded: [~r"/_build/", ~r"/deps/"]
      },
      requires: [".credo/checks/**/*.ex"],
      strict: false,  # Don't fail on refactoring opportunities
      color: true,
      checks: [
        # Consistency Checks (High Priority - Enforce These)
        {Credo.Check.Consistency.ExceptionNames, priority: :high},
        {Credo.Check.Consistency.LineEndings, priority: :high},
        {Credo.Check.Consistency.SpaceAroundOperators, priority: :high},
        {Credo.Check.Consistency.SpaceInParentheses, priority: :high},
        {Credo.Check.Consistency.TabsOrSpaces, priority: :high},

        # Readability Checks (Medium Priority - Warn but Don't Block)
        {Credo.Check.Readability.AliasOrder, priority: :normal},
        {Credo.Check.Readability.FunctionNames, priority: :high},  # Enforce ? and ! conventions
        {Credo.Check.Readability.LargeNumbers, priority: :low},
        {Credo.Check.Readability.MaxLineLength, priority: :normal, max_length: 120},  # Relaxed from default 80
        {Credo.Check.Readability.ModuleAttributeNames, priority: :normal},
        {Credo.Check.Readability.ModuleDoc, false},  # Disabled - not needed for all modules
        {Credo.Check.Readability.ModuleNames, priority: :high},
        {Credo.Check.Readability.ParenthesesInCondition, priority: :normal},
        {Credo.Check.Readability.PredicateFunctionNames, priority: :high},  # Enforce ? suffix
        {Credo.Check.Readability.TrailingBlankLine, priority: :normal},
        {Credo.Check.Readability.TrailingWhiteSpace, priority: :high},
        {Credo.Check.Readability.VariableNames, priority: :normal},

        # Refactoring Opportunities (Low Priority - Information Only)
        {Credo.Check.Refactor.CondStatements, priority: :high},  # Aligns with pattern matching preference
        {Credo.Check.Refactor.CyclomaticComplexity, priority: :low, max_complexity: 10},
        {Credo.Check.Refactor.FunctionArity, priority: :low, max_arity: 6},  # Relaxed
        {Credo.Check.Refactor.NegatedConditionsInUnless, priority: :normal},
        {Credo.Check.Refactor.NegatedConditionsWithElse, priority: :high},
        {Credo.Check.Refactor.Nesting, priority: :low, max_nesting: 3},
        {Credo.Check.Refactor.PipeChainStart,
          priority: :normal,
          excluded_argument_types: [:atom, :binary, :fn, :keyword],
          excluded_functions: []},

        # Design Checks (High Priority for Critical Issues)
        {Credo.Check.Design.AliasUsage, priority: :low, if_nested_deeper_than: 2},
        {Credo.Check.Design.TagTODO, false},  # We use TodoWrite tool instead
        {Credo.Check.Design.TagFIXME, priority: :normal},

        # Warning Checks (All High Priority - These are bugs)
        {Credo.Check.Warning.BoolOperationOnSameValues, priority: :high},
        {Credo.Check.Warning.IExPry, priority: :high},
        {Credo.Check.Warning.IoInspect, priority: :high},
        {Credo.Check.Warning.OperationOnSameValues, priority: :high},
        {Credo.Check.Warning.OperationWithConstantResult, priority: :high},
        {Credo.Check.Warning.UnusedEnumOperation, priority: :high},
        {Credo.Check.Warning.UnusedFileOperation, priority: :high},
        {Credo.Check.Warning.UnusedKeywordOperation, priority: :high},
        {Credo.Check.Warning.UnusedListOperation, priority: :high},
        {Credo.Check.Warning.UnusedPathOperation, priority: :high},
        {Credo.Check.Warning.UnusedRegexOperation, priority: :high},
        {Credo.Check.Warning.UnusedStringOperation, priority: :high},
        {Credo.Check.Warning.UnusedTupleOperation, priority: :high},

        # Custom checks aligned with AGENTS.md principles
        {Credo.Check.Refactor.CaseTrivialMatches, priority: :high},  # Use pattern matching
        {Credo.Check.Refactor.MatchInCondition, priority: :high},    # Prefer pattern matching
        {Credo.Check.Readability.WithSingleClause, priority: :normal}, # Proper with usage

        # Custom Concurrency Checks (High Priority - Critical for async: true tests)
        {Credo.Check.Concurrency.NoNamedGenServers, priority: :high},
        {Credo.Check.Concurrency.NoNamedEtsTables, priority: :high},
        # Excluded files: OS process polling (termination.ex), exponential backoff (seed_models.ex, reflector.ex),
        # test mock timing simulation (mock_execution.ex), MCP init polling (client.ex) - legitimate delay patterns, not synchronization
        {Credo.Check.Concurrency.NoProcessSleep, [
          priority: :high,
          files: %{excluded: [
            "lib/quoracle/actions/shell/termination.ex",  # Polling OS process termination after SIGTERM
            "lib/quoracle/actions/router/mock_execution.ex",  # Test mock simulating sleep command delay
            "lib/quoracle/agent/reflector.ex",            # Exponential backoff for LLM reflection retries
            "lib/quoracle/mcp/client.ex",                 # Polling external anubis_mcp for async MCP handshake
            "lib/quoracle/mcp/connection_manager.ex"      # Extracted from client.ex - same MCP init polling
          ]}
        ]},
        {Credo.Check.Concurrency.NoProcessDictionary, priority: :high},
        {Credo.Check.Concurrency.NoSetupAll, [
          priority: :high,
          # api_test.exs: Module-level Goth mock required - ExVCR Finch adapter can't intercept Goth's Hackney OAuth requests
          # image_compressor_test.exs, message_builder_compression_test.exs: Immutable read-only test fixtures
          #   (binary images) generated once and shared. Safe with async: true because binaries are thread-safe.
          files: %{excluded: [
            "test/quoracle/actions/api_test.exs",
            "test/quoracle/utils/image_compressor_test.exs",
            "test/quoracle/models/model_query/message_builder_compression_test.exs"
          ]}
        ]},
        {Credo.Check.Concurrency.TestsWithoutAsync, priority: :high},
        {Credo.Check.Concurrency.StaticTelemetryHandlerId, priority: :high},
        {Credo.Check.Concurrency.NoHardcodedPubSub, [
          priority: :high,
          # Exclude tests that intentionally use global PubSub to verify isolation boundaries
          files: %{excluded: [
            "test/support/pubsub_isolation_test.exs",
            "test/quoracle/pubsub/agent_events_explicit_test.exs",
            "test/quoracle/agent/message_handler_pubsub_test.exs",
            "test/quoracle/agent/core_pubsub_test.exs",
            "test/quoracle_web/live/dashboard_3panel_integration_test.exs",
            "test/quoracle/actions/wait_isolation_test.exs",
            "test/quoracle/actions/orient_isolation_test.exs"
          ]}
        ]},

        # Custom Quality Checks
        {Credo.Check.Quality.MissingSpec, priority: :normal},

        # Custom Readability Checks
        {Credo.Check.Readability.IsPrefixNaming, priority: :normal},
        {Credo.Check.Readability.MissingDoc, priority: :normal},

        # Custom Warning Checks (High Priority - Catch bugs and anti-patterns)
        # Excluded files:
        # - model_registry.ex: loads from database (trusted source) at boot to create atoms for
        #   valid models. This enables String.to_existing_atom elsewhere to prevent atom table
        #   exhaustion from user input. See model_query.ex for the secured query path.
        # - spawn.ex: normalize_field_keys uses String.to_atom on hardcoded whitelist of
        #   known field names (not user input). Whitelist prevents atom exhaustion.
        # - mcp/client.ex: map_to_keyword converts auth keys from MCP server config (not user input).
        #   Limited to standard auth keys (token, api_key, etc.) from trusted configuration.
        {Credo.Check.Warning.NoStringToAtom, [
          priority: :high,
          files: %{excluded: [
            "lib/quoracle/models/model_registry.ex",
            "lib/quoracle/actions/spawn.ex",
            "lib/quoracle/mcp/client.ex",
            "lib/quoracle/mcp/connection_manager.ex",  # Extracted from client.ex - same auth key handling
            # Deserialization modules: converting our own serialized atoms back from DB strings
            "lib/quoracle/profiles/table_profiles.ex",  # capability_groups validated on insert
            "lib/quoracle/agent/dyn_sup.ex",            # config keys validated against @config_keys whitelist
            "lib/quoracle/agent/core/persistence/ace_state.ex"  # lesson/action/history types from own serialization
          ]}
        ]},
        {Credo.Check.Warning.OutdatedSandboxPattern, priority: :high},
        {Credo.Check.Warning.CodeEnsureLoadedInTests, priority: :high},
        {Credo.Check.Warning.IoInsteadOfLogger, priority: :high},
        {Credo.Check.Warning.RawSpawn, priority: :high},
        {Credo.Check.Warning.SequentialRegistryRegister, priority: :high},
        {Credo.Check.Warning.FunctionExportedTest, priority: :high},
        {Credo.Check.Warning.SkippedTests, priority: :high},
        {Credo.Check.Warning.DbgInProduction, priority: :high},
        {Credo.Check.Warning.LegacyCodeMarkers, priority: :high},
        {Credo.Check.Warning.GenServerStopFiniteTimeout, [
          priority: :high,
          # agent_api_call_test.exs: Agents with seed_action loop infinitely, :infinity would hang forever
          files: %{excluded: ["test/quoracle/integration/agent_api_call_test.exs"]}
        ]},
        {Credo.Check.Warning.SandboxAllowInInit, priority: :high},
        {Credo.Check.Warning.MonitoringSandboxOwner, priority: :high},
        {Credo.Check.Warning.OrInAssertion, priority: :high},
        {Credo.Check.Warning.LiteralMonitorExitReason, priority: :high},
        {Credo.Check.Warning.GlobalLoggerConfigInTests, priority: :high},
        {Credo.Check.Warning.GlobalAppConfigInTests, priority: :high},
        {Credo.Check.Warning.HardcodedTmpPath, priority: :high},

        # Local Custom Checks (Quoracle-specific)
        {Credo.Check.Custom.NoRawAgentSpawn, priority: :high}
      ]
    }
  ]
}
