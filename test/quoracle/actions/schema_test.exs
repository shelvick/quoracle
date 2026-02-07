defmodule Quoracle.Actions.SchemaTest do
  use ExUnit.Case, async: true
  alias Quoracle.Actions.Schema

  @valid_actions [
    :spawn_child,
    :wait,
    :send_message,
    :orient,
    :answer_engine,
    :execute_shell,
    :fetch_web,
    :call_api,
    :call_mcp,
    :todo,
    :generate_secret,
    :search_secrets,
    :dismiss_child,
    :generate_images
  ]

  describe "get_schema/1" do
    test "returns schema for valid action spawn_child" do
      assert {:ok, schema} = Schema.get_schema(:spawn_child)
      assert Map.has_key?(schema, :required_params)
      assert Map.has_key?(schema, :optional_params)
      assert Map.has_key?(schema, :param_types)
      assert Map.has_key?(schema, :consensus_rules)
    end

    test "returns schema for valid action wait" do
      assert {:ok, schema} = Schema.get_schema(:wait)
      assert schema.required_params == []
      assert :wait in schema.optional_params
    end

    test "returns error for unknown action" do
      assert {:error, :unknown_action} = Schema.get_schema(:invalid_action)
    end

    test "returns error for nil action" do
      assert {:error, :unknown_action} = Schema.get_schema(nil)
    end
  end

  describe "list_actions/0" do
    test "returns all 18 action atoms" do
      actions = Schema.list_actions()
      assert length(actions) == 22
    end
  end

  describe "get_action_priority/1" do
    test "returns priority 1 for orient (most conservative)" do
      assert Schema.get_action_priority(:orient) == 1
    end

    test "returns priority 2 for wait" do
      assert Schema.get_action_priority(:wait) == 2
    end

    test "returns priority 3 for send_message" do
      assert Schema.get_action_priority(:send_message) == 3
    end

    test "returns priority 6 for fetch_web" do
      assert Schema.get_action_priority(:fetch_web) == 6
    end

    test "returns priority 10 for answer_engine" do
      assert Schema.get_action_priority(:answer_engine) == 10
    end

    test "returns priority 11 for todo" do
      assert Schema.get_action_priority(:todo) == 11
    end

    test "returns priority 16 for call_mcp" do
      assert Schema.get_action_priority(:call_mcp) == 16
    end

    test "returns priority 17 for call_api" do
      assert Schema.get_action_priority(:call_api) == 17
    end

    test "returns priority 18 for execute_shell" do
      assert Schema.get_action_priority(:execute_shell) == 18
    end

    test "returns priority 22 for spawn_child" do
      assert Schema.get_action_priority(:spawn_child) == 22
    end

    test "returns error for unknown action" do
      assert {:error, :unknown_action} = Schema.get_action_priority(:invalid_action)
    end

    test "returns error for nil action" do
      assert {:error, :unknown_action} = Schema.get_action_priority(nil)
    end

    test "lower priority numbers are more conservative" do
      orient_priority = Schema.get_action_priority(:orient)
      spawn_priority = Schema.get_action_priority(:spawn_child)
      assert orient_priority < spawn_priority
    end
  end

  describe "get_priorities/0" do
    test "returns map with all 21 actions" do
      priorities = Schema.get_priorities()
      assert is_map(priorities)
      assert map_size(priorities) == 22
    end

    test "includes all valid actions as keys" do
      priorities = Schema.get_priorities()

      Enum.each(@valid_actions, fn action ->
        assert Map.has_key?(priorities, action)
      end)
    end

    test "all priorities are integers between 1 and 22" do
      priorities = Schema.get_priorities()
      values = Map.values(priorities)
      assert Enum.all?(values, &is_integer/1)
      assert Enum.all?(values, &(&1 >= 1 and &1 <= 22))
    end

    test "all priorities are unique (no two actions share a priority)" do
      priorities = Schema.get_priorities()
      values = Map.values(priorities)
      assert length(Enum.uniq(values)) == length(values)
      assert Enum.all?(values, &is_integer/1)
      assert Enum.all?(values, &(&1 > 0))
    end

    test "orient has lowest priority (1)" do
      priorities = Schema.get_priorities()
      assert priorities.orient == 1
    end

    test "spawn_child has highest priority (22)" do
      priorities = Schema.get_priorities()
      assert priorities.spawn_child == 22
    end
  end

  describe "validate_action_type/1" do
    test "accepts valid actions" do
      for action <- @valid_actions do
        assert {:ok, ^action} = Schema.validate_action_type(action)
      end
    end

    test "rejects invalid actions" do
      assert {:error, :unknown_action} = Schema.validate_action_type(:not_an_action)
      assert {:error, :unknown_action} = Schema.validate_action_type("spawn_child")
      assert {:error, :unknown_action} = Schema.validate_action_type(nil)
    end
  end

  describe "wait_required?/1" do
    test "returns false for :wait action" do
      assert Schema.wait_required?(:wait) == false
    end

    test "returns true for all other actions" do
      non_wait_actions = @valid_actions -- [:wait]

      for action <- non_wait_actions do
        assert Schema.wait_required?(action) == true,
               "Expected wait_required?(#{inspect(action)}) to be true"
      end
    end

    test "returns true for :spawn_child" do
      assert Schema.wait_required?(:spawn_child) == true
    end

    test "returns true for :orient" do
      assert Schema.wait_required?(:orient) == true
    end

    test "returns true for :send_message" do
      assert Schema.wait_required?(:send_message) == true
    end

    test "raises for unknown action" do
      assert_raise FunctionClauseError, fn ->
        Schema.wait_required?(:invalid_action)
      end
    end
  end

  describe "spawn_child action definition" do
    test "has correct required params" do
      {:ok, schema} = Schema.get_schema(:spawn_child)

      assert schema.required_params == [
               :task_description,
               :success_criteria,
               :immediate_context,
               :approach_guidance,
               :profile
             ]
    end

    test "has correct optional params" do
      {:ok, schema} = Schema.get_schema(:spawn_child)
      # NOTE: :models intentionally removed - agents can't know which
      # models are configured.
      assert :role in schema.optional_params
      assert :downstream_constraints in schema.optional_params
      refute :models in schema.optional_params
    end

    test "has correct param types" do
      {:ok, schema} = Schema.get_schema(:spawn_child)
      assert schema.param_types.task_description == :string
      assert schema.param_types.downstream_constraints == :string
      # models types removed from schema
      refute Map.has_key?(schema.param_types, :models)
    end

    test "has consensus rules defined" do
      {:ok, schema} = Schema.get_schema(:spawn_child)
      assert schema.consensus_rules.task_description == {:semantic_similarity, threshold: 0.95}

      assert schema.consensus_rules.downstream_constraints ==
               {:semantic_similarity, threshold: 0.90}

      # models consensus rules removed from schema
      refute Map.has_key?(schema.consensus_rules, :models)
    end

    test "enum fields use correct consensus rules (not semantic_similarity)" do
      {:ok, schema} = Schema.get_schema(:spawn_child)

      # Enum fields should use mode_selection or exact_match, NOT semantic_similarity
      assert schema.consensus_rules.cognitive_style == :mode_selection,
             "cognitive_style is enum with 5 values, should use :mode_selection"

      assert schema.consensus_rules.output_style == :mode_selection,
             "output_style is enum with 4 values, should use :mode_selection"

      assert schema.consensus_rules.delegation_strategy == :exact_match,
             "delegation_strategy is enum with 3 values, should use :exact_match"
    end
  end

  describe "wait action definition" do
    test "has no required params" do
      {:ok, schema} = Schema.get_schema(:wait)
      assert schema.required_params == []
    end

    test "has wait as optional param" do
      # Note: auto_complete_todo is injected by Validator, not in schema definitions
      {:ok, schema} = Schema.get_schema(:wait)
      assert schema.optional_params == [:wait]
    end

    test "has correct consensus rule for wait" do
      {:ok, schema} = Schema.get_schema(:wait)
      assert schema.consensus_rules.wait == {:percentile, 50}
    end
  end

  describe "send_message action definition" do
    test "has correct required params" do
      {:ok, schema} = Schema.get_schema(:send_message)
      assert :to in schema.required_params
      assert :content in schema.required_params
    end

    test "has correct param types" do
      {:ok, schema} = Schema.get_schema(:send_message)
      assert schema.param_types.to == {:union, [:atom, {:list, :string}]}
      assert schema.param_types.content == :string
    end

    test "has correct consensus rules" do
      {:ok, schema} = Schema.get_schema(:send_message)
      assert schema.consensus_rules.to == :exact_match
      assert schema.consensus_rules.content == {:semantic_similarity, threshold: 0.85}
    end
  end

  describe "orient action definition" do
    test "has all required reflection params" do
      {:ok, schema} = Schema.get_schema(:orient)
      required = schema.required_params
      assert :current_situation in required
      assert :goal_clarity in required
      assert :available_resources in required
      assert :key_challenges in required
    end

    test "has all optional reflection params" do
      {:ok, schema} = Schema.get_schema(:orient)
      optional = schema.optional_params
      assert :assumptions in optional
      assert :unknowns in optional
      assert :approach_options in optional
      assert :parallelization_opportunities in optional
      assert :risk_factors in optional
      assert :success_criteria in optional
      assert :next_steps in optional
      assert :constraints_impact in optional
    end

    test "all params use semantic similarity consensus" do
      {:ok, schema} = Schema.get_schema(:orient)

      # TEST-FIX: auto_complete_todo uses :exact_match (boolean), exclude from semantic_similarity check
      params_to_check =
        (schema.required_params ++ schema.optional_params)
        |> Enum.reject(&(&1 == :auto_complete_todo))

      Enum.each(params_to_check, fn param ->
        assert schema.consensus_rules[param] == {:semantic_similarity, threshold: 0.8}
      end)
    end
  end

  describe "answer_engine action definition" do
    test "has prompt as required param" do
      {:ok, schema} = Schema.get_schema(:answer_engine)
      assert schema.required_params == [:prompt]
    end

    test "has semantic similarity consensus for prompt" do
      {:ok, schema} = Schema.get_schema(:answer_engine)
      assert schema.consensus_rules.prompt == {:semantic_similarity, threshold: 0.95}
    end
  end

  describe "execute_shell action definition" do
    test "has XOR params command and check_id" do
      {:ok, schema} = Schema.get_schema(:execute_shell)
      assert schema.xor_params == [[:command], [:check_id]]
    end

    test "has working_dir as optional param" do
      {:ok, schema} = Schema.get_schema(:execute_shell)
      assert :working_dir in schema.optional_params
    end

    test "has exact match consensus for all params" do
      {:ok, schema} = Schema.get_schema(:execute_shell)
      assert schema.consensus_rules.command == :exact_match
      assert schema.consensus_rules.check_id == :exact_match
      assert schema.consensus_rules.working_dir == :exact_match
    end
  end

  describe "fetch_web action definition" do
    test "has url as required param" do
      {:ok, schema} = Schema.get_schema(:fetch_web)
      assert :url in schema.required_params
    end

    test "has correct optional params" do
      {:ok, schema} = Schema.get_schema(:fetch_web)
      assert :security_check in schema.optional_params
      assert :timeout in schema.optional_params
      assert :user_agent in schema.optional_params
      assert :follow_redirects in schema.optional_params
    end

    test "has correct param types" do
      {:ok, schema} = Schema.get_schema(:fetch_web)
      assert schema.param_types.url == :string
      assert schema.param_types.security_check == :boolean
      assert schema.param_types.timeout == :number
      assert schema.param_types.user_agent == :string
      assert schema.param_types.follow_redirects == :boolean
    end
  end

  describe "call_api action definition" do
    test "has correct required params" do
      {:ok, schema} = Schema.get_schema(:call_api)
      assert :api_type in schema.required_params
      assert :url in schema.required_params
    end

    test "has correct optional params including auth" do
      {:ok, schema} = Schema.get_schema(:call_api)
      assert :method in schema.optional_params
      assert :headers in schema.optional_params
      assert :auth in schema.optional_params
      assert :query in schema.optional_params
    end

    test "has correct consensus rules" do
      {:ok, schema} = Schema.get_schema(:call_api)
      assert schema.consensus_rules.api_type == :exact_match
      assert schema.consensus_rules.url == :exact_match
      assert schema.consensus_rules.method == :exact_match
      assert schema.consensus_rules.timeout == {:percentile, 100}
      assert schema.consensus_rules.max_body_size == {:percentile, 100}
      assert schema.consensus_rules.auth == :exact_match
    end
  end

  describe "call_mcp action definition" do
    test "has correct optional params for agent-driven discovery" do
      {:ok, schema} = Schema.get_schema(:call_mcp)

      # v20.0: All params optional (XOR handles mutual exclusion)
      expected_optional = [
        :transport,
        :command,
        :url,
        :connection_id,
        :tool,
        :arguments,
        :terminate,
        :timeout
      ]

      Enum.each(expected_optional, fn param ->
        assert param in schema.optional_params,
               "Expected #{inspect(param)} in optional_params"
      end)
    end

    test "has exact match consensus rules for connection params" do
      {:ok, schema} = Schema.get_schema(:call_mcp)
      # v20.0: Connection-related params use exact_match
      assert schema.consensus_rules.transport == :exact_match
      assert schema.consensus_rules.command == :exact_match
      assert schema.consensus_rules.url == :exact_match
      assert schema.consensus_rules.connection_id == :exact_match
      assert schema.consensus_rules.tool == :exact_match
      assert schema.consensus_rules.arguments == :exact_match
      assert schema.consensus_rules.terminate == :exact_match
    end

    test "has percentile consensus rule for timeout" do
      {:ok, schema} = Schema.get_schema(:call_mcp)
      # v20.0: Timeout uses percentile 50 for numeric consensus
      assert schema.consensus_rules.timeout == {:percentile, 50}
    end
  end

  # ACTION_Schema v20.0 - MCP Action Schema Update
  # ARC Verification Criteria for call_mcp agent-driven discovery redesign
  describe "call_mcp v20.0 schema (agent-driven discovery)" do
    test "R1: call_mcp has xor_params for transport vs connection_id" do
      # [UNIT] - WHEN get_schema(:call_mcp) called THEN xor_params includes [[:transport], [:connection_id]]
      {:ok, schema} = Schema.get_schema(:call_mcp)
      assert Map.has_key?(schema, :xor_params)
      assert schema.xor_params == [[:transport], [:connection_id]]
    end

    test "R2: call_mcp transport is enum type" do
      # [UNIT] - WHEN get_schema(:call_mcp) called THEN transport has enum type [:stdio, :http]
      {:ok, schema} = Schema.get_schema(:call_mcp)
      assert schema.param_types.transport == {:enum, [:stdio, :http]}
    end

    test "R3: call_mcp has no required params" do
      # [UNIT] - WHEN get_schema(:call_mcp) called THEN required_params is empty (XOR handles requirements)
      {:ok, schema} = Schema.get_schema(:call_mcp)
      assert schema.required_params == []
    end

    test "R4: call_mcp has descriptions for all params" do
      # [UNIT] - WHEN get_schema(:call_mcp) called THEN all 8 params have descriptions
      {:ok, schema} = Schema.get_schema(:call_mcp)

      expected_params = [
        :transport,
        :command,
        :url,
        :connection_id,
        :tool,
        :arguments,
        :terminate,
        :timeout
      ]

      Enum.each(expected_params, fn param ->
        assert Map.has_key?(schema.param_descriptions, param),
               "Missing param_description for #{inspect(param)}"
      end)

      assert map_size(schema.param_descriptions) == 9
    end
  end

  describe "consensus rules validation" do
    test "all required params have consensus rules" do
      for action <- @valid_actions do
        {:ok, schema} = Schema.get_schema(action)

        for param <- schema.required_params do
          assert Map.has_key?(schema.consensus_rules, param),
                 "Missing consensus rule for required param #{param} in action #{action}"
        end
      end
    end

    test "all optional params have consensus rules" do
      for action <- @valid_actions do
        {:ok, schema} = Schema.get_schema(action)

        for param <- schema.optional_params do
          assert Map.has_key?(schema.consensus_rules, param),
                 "Missing consensus rule for optional param #{param} in action #{action}"
        end
      end
    end
  end

  describe "performance" do
    test "get_schema/1 completes in O(1) time" do
      # Warm up
      Schema.get_schema(:spawn_child)

      # Measure time for multiple lookups
      times =
        for _ <- 1..100 do
          {time, _} = :timer.tc(fn -> Schema.get_schema(:spawn_child) end)
          time
        end

      avg_time = Enum.sum(times) / length(times)
      # Should be very fast, under 100 microseconds
      assert avg_time < 100
    end
  end

  # ACTION_Schema v22.0 - Dismiss Child Action
  # ARC Verification Criteria for dismiss_child action registration
  # WorkGroupID: feat-20251224-dismiss-child
  # Packet: 1 (Infrastructure)
  describe "dismiss_child action definition (v22.0)" do
    # R1: Action Registered
    test "dismiss_child in action list" do
      # [UNIT] - WHEN list_actions/0 called THEN includes :dismiss_child
      actions = Schema.list_actions()
      assert :dismiss_child in actions
    end

    # R2: Schema Defined
    test "dismiss_child schema exists" do
      # [UNIT] - WHEN get_schema(:dismiss_child) called THEN returns valid schema
      assert {:ok, schema} = Schema.get_schema(:dismiss_child)
      assert is_map(schema)
      assert Map.has_key?(schema, :required_params)
      assert Map.has_key?(schema, :optional_params)
      assert Map.has_key?(schema, :param_types)
      assert Map.has_key?(schema, :consensus_rules)
    end

    # R3: Required Params
    test "dismiss_child requires child_id" do
      # [UNIT] - WHEN get_schema(:dismiss_child) called THEN required_params includes :child_id
      {:ok, schema} = Schema.get_schema(:dismiss_child)
      assert :child_id in schema.required_params
    end

    # R4: Optional Reason
    test "dismiss_child has optional reason" do
      # [UNIT] - WHEN get_schema(:dismiss_child) called THEN optional_params includes :reason
      {:ok, schema} = Schema.get_schema(:dismiss_child)
      assert :reason in schema.optional_params
    end

    # R5: Param Types
    test "dismiss_child param types are string" do
      # [UNIT] - WHEN get_schema(:dismiss_child) called THEN child_id and reason are :string type
      {:ok, schema} = Schema.get_schema(:dismiss_child)
      assert schema.param_types[:child_id] == :string
      assert schema.param_types[:reason] == :string
    end

    # R6: Consensus Rules
    test "dismiss_child consensus rules defined" do
      # [UNIT] - WHEN get_schema(:dismiss_child) called THEN child_id uses :exact_match, reason uses :first_non_nil
      {:ok, schema} = Schema.get_schema(:dismiss_child)
      assert schema.consensus_rules[:child_id] == :exact_match
      assert schema.consensus_rules[:reason] == :first_non_nil
    end

    # R7: Action Description Present
    test "dismiss_child has action description" do
      # [UNIT] - WHEN get_action_description(:dismiss_child) called THEN returns WHEN/HOW guidance
      description = Schema.get_action_description(:dismiss_child)
      assert is_binary(description)
      assert String.contains?(description, "WHEN")
      assert String.contains?(description, "HOW")
    end

    # R8: Action Priority Defined
    test "dismiss_child has priority 20" do
      # [UNIT] - WHEN get_action_priority(:dismiss_child) called THEN returns 20
      assert Schema.get_action_priority(:dismiss_child) == 20
    end

    # R9: Total Actions Updated
    test "action list has 21 actions" do
      # [UNIT] - WHEN list_actions/0 called THEN returns 21 actions (includes record_cost)
      actions = Schema.list_actions()
      assert length(actions) == 22
    end
  end

  # ACTION_Schema v21.0 - Search Secrets Action
  # ARC Verification Criteria for search_secrets action registration
  describe "search_secrets action definition (v21.0)" do
    # R1: Action Registered
    test "search_secrets in action list" do
      # [UNIT] - WHEN list_actions/0 called THEN includes :search_secrets
      actions = Schema.list_actions()
      assert :search_secrets in actions
    end

    # R2: Schema Defined
    test "search_secrets schema exists" do
      # [UNIT] - WHEN get_schema(:search_secrets) called THEN returns valid schema
      assert {:ok, schema} = Schema.get_schema(:search_secrets)
      assert is_map(schema)
      assert Map.has_key?(schema, :required_params)
      assert Map.has_key?(schema, :optional_params)
      assert Map.has_key?(schema, :param_types)
      assert Map.has_key?(schema, :consensus_rules)
    end

    # R3: Required Params
    test "search_secrets requires search_terms" do
      # [UNIT] - WHEN get_schema(:search_secrets) called THEN required_params includes :search_terms
      {:ok, schema} = Schema.get_schema(:search_secrets)
      assert :search_terms in schema.required_params
    end

    # R4: Param Type List String
    test "search_secrets search_terms is list of strings" do
      # [UNIT] - WHEN get_schema(:search_secrets) called THEN search_terms has type {:list, :string}
      {:ok, schema} = Schema.get_schema(:search_secrets)
      assert schema.param_types[:search_terms] == {:list, :string}
    end

    # R5: Param Description Present
    test "search_secrets has param description" do
      # [UNIT] - WHEN get_schema(:search_secrets) called THEN param_descriptions includes search_terms
      {:ok, schema} = Schema.get_schema(:search_secrets)
      assert Map.has_key?(schema.param_descriptions, :search_terms)
      assert is_binary(schema.param_descriptions[:search_terms])
    end

    # R6: Consensus Rule Defined
    test "search_secrets has union_merge consensus rule" do
      # [UNIT] - WHEN get_schema(:search_secrets) called THEN consensus_rules includes search_terms: :union_merge
      {:ok, schema} = Schema.get_schema(:search_secrets)
      assert schema.consensus_rules[:search_terms] == :union_merge
    end

    # R7: Action Description Present
    test "search_secrets has action description" do
      # [UNIT] - WHEN get_action_description(:search_secrets) called THEN returns WHEN/HOW guidance
      description = Schema.get_action_description(:search_secrets)
      assert is_binary(description)
      assert String.contains?(description, "WHEN")
      assert String.contains?(description, "HOW")
    end

    # R8: Action Priority Defined
    test "search_secrets has priority 8" do
      # [UNIT] - WHEN get_action_priority(:search_secrets) called THEN returns 8
      assert Schema.get_action_priority(:search_secrets) == 8
    end

    # R9: Total Actions Updated
    test "action list has 21 actions" do
      # [UNIT] - WHEN list_actions/0 called THEN returns 21 actions (includes record_cost)
      actions = Schema.list_actions()
      assert length(actions) == 22
    end
  end

  # ACTION_Schema v22.0 - Announcement Target for SendMessage
  # ARC Verification Criteria for :announcement target addition
  describe "send_message announcement target (v22.0)" do
    # R1: Announcement Atom Exists
    test "send_message_targets includes :announcement" do
      # [UNIT] - WHEN __send_message_targets__/0 called THEN includes :announcement
      targets = Schema.__send_message_targets__()
      assert :announcement in targets
    end

    # R2: Param Description Updated
    test "send_message to param describes announcement target" do
      # [UNIT] - WHEN get_schema(:send_message) called THEN param_descriptions.to mentions "announcement"
      {:ok, schema} = Schema.get_schema(:send_message)
      to_description = schema.param_descriptions[:to]

      assert is_binary(to_description)
      assert to_description =~ "announcement"
    end

    # R3: Param Description Distinguishes Children
    test "send_message to param clarifies children is direct only" do
      # [UNIT] - WHEN get_schema(:send_message) called THEN param_descriptions.to clarifies "children" is direct only
      {:ok, schema} = Schema.get_schema(:send_message)
      to_description = schema.param_descriptions[:to]

      assert is_binary(to_description)
      # Should clarify that "children" means direct children only (both concepts must be present)
      assert to_description =~ "children"
      assert to_description =~ "direct"
    end

    # R4: Target Count Updated
    test "send_message_targets has 5 targets" do
      # [UNIT] - WHEN __send_message_targets__/0 called THEN returns 5 targets
      targets = Schema.__send_message_targets__()
      assert length(targets) == 5

      # Verify all expected targets are present
      assert :parent in targets
      assert :children in targets
      assert :all_children in targets
      assert :user in targets
      assert :announcement in targets
    end
  end

  # ACTION_Schema v23.0 - generate_images Action
  # ARC Verification Criteria for generate_images action registration
  # WorkGroupID: feat-20251229-052855
  # Packet: 3 (Action Integration)
  describe "generate_images action definition (v23.0)" do
    # R1: Action Registered
    test "generate_images in action list" do
      # [UNIT] - WHEN list_actions/0 called THEN includes :generate_images
      actions = Schema.list_actions()
      assert :generate_images in actions
    end

    # R2: Schema Defined
    test "generate_images schema exists" do
      # [UNIT] - WHEN get_schema(:generate_images) called THEN returns valid schema
      assert {:ok, schema} = Schema.get_schema(:generate_images)
      assert is_map(schema)
      assert Map.has_key?(schema, :required_params)
      assert Map.has_key?(schema, :optional_params)
      assert Map.has_key?(schema, :param_types)
      assert Map.has_key?(schema, :consensus_rules)
    end

    # R3: Required Params
    test "generate_images requires prompt" do
      # [UNIT] - WHEN get_schema(:generate_images) called THEN required_params includes :prompt
      {:ok, schema} = Schema.get_schema(:generate_images)
      assert :prompt in schema.required_params
    end

    # R4: Optional Source Image
    test "generate_images has optional source_image" do
      # [UNIT] - WHEN get_schema(:generate_images) called THEN optional_params includes :source_image
      {:ok, schema} = Schema.get_schema(:generate_images)
      assert :source_image in schema.optional_params
    end

    # R5: Param Types
    test "generate_images param types are string" do
      # [UNIT] - WHEN get_schema(:generate_images) called THEN prompt and source_image are :string type
      {:ok, schema} = Schema.get_schema(:generate_images)
      assert schema.param_types[:prompt] == :string
      assert schema.param_types[:source_image] == :string
    end

    # R6: Consensus Rules
    test "generate_images consensus rules defined" do
      # [UNIT] - WHEN get_schema(:generate_images) called THEN prompt uses semantic_similarity, source_image uses first_non_nil
      {:ok, schema} = Schema.get_schema(:generate_images)
      assert schema.consensus_rules[:prompt] == {:semantic_similarity, threshold: 0.95}
      assert schema.consensus_rules[:source_image] == :first_non_nil
    end

    # R7: Action Description Present
    test "generate_images has action description" do
      # [UNIT] - WHEN get_action_description(:generate_images) called THEN returns WHEN/HOW guidance
      description = Schema.get_action_description(:generate_images)
      assert is_binary(description)
      assert String.contains?(description, "WHEN")
      assert String.contains?(description, "HOW")
    end

    # R8: Action Priority Defined
    test "generate_images has priority 14" do
      # [UNIT] - WHEN get_action_priority(:generate_images) called THEN returns 14
      assert Schema.get_action_priority(:generate_images) == 14
    end

    # R9: Total Actions Updated
    test "action list has 21 actions" do
      # [UNIT] - WHEN list_actions/0 called THEN returns 21 actions (includes record_cost)
      actions = Schema.list_actions()
      assert length(actions) == 22
    end

    # Additional: Param Descriptions
    test "generate_images has param descriptions" do
      # [UNIT] - WHEN get_schema(:generate_images) called THEN param_descriptions exist
      {:ok, schema} = Schema.get_schema(:generate_images)
      assert Map.has_key?(schema.param_descriptions, :prompt)
      assert Map.has_key?(schema.param_descriptions, :source_image)
      assert is_binary(schema.param_descriptions[:prompt])
      assert is_binary(schema.param_descriptions[:source_image])
    end
  end
end
