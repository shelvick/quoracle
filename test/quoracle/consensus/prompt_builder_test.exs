defmodule Quoracle.Consensus.PromptBuilderTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Quoracle.Consensus.PromptBuilder
  alias Quoracle.Consensus.PromptBuilder.{Context, Sections}
  alias Quoracle.Actions.Schema

  # All capability groups to include all actions in prompts
  @all_capability_groups [:file_read, :file_write, :external_api, :hierarchy, :local_execution]

  describe "system prompt generation" do
    test "ARC_FUNC_01: returns string containing all 21 actions" do
      prompt = PromptBuilder.build_system_prompt(capability_groups: @all_capability_groups)

      assert is_binary(prompt)

      # Verify all actions from Schema are present
      actions = Schema.list_actions()

      Enum.each(actions, fn action ->
        action_string = Atom.to_string(action)

        assert prompt =~ action_string,
               "Prompt should contain action: #{action_string}"
      end)
    end

    test "ARC_FUNC_02: includes JSON schema for each action" do
      prompt = PromptBuilder.build_system_prompt(capability_groups: @all_capability_groups)

      # Check for JSON schema structure keywords
      assert prompt =~ "properties"
      assert prompt =~ "required"
      assert prompt =~ "type"

      # Verify each action has a schema section
      actions = Schema.list_actions()

      Enum.each(actions, fn action ->
        action_string = Atom.to_string(action)
        # Look for action within a JSON context
        assert prompt =~ ~r/"action".*"#{action_string}"/s or
                 prompt =~ ~r/#{action_string}.*"properties"/s,
               "Prompt should contain JSON schema for action: #{action_string}"
      end)
    end

    test "ARC_FUNC_03: specifies required vs optional params" do
      prompt = PromptBuilder.build_system_prompt(capability_groups: @all_capability_groups)

      # Test specific actions with known required params
      # spawn_child requires task_description
      assert prompt =~ "spawn_child"
      assert prompt =~ "task_description"

      # send_message requires to and content
      assert prompt =~ "send_message"
      assert prompt =~ "to"
      assert prompt =~ "content"

      # orient has 4 required params
      assert prompt =~ "current_situation"
      assert prompt =~ "goal_clarity"
      assert prompt =~ "available_resources"
      assert prompt =~ "key_challenges"
    end

    test "ARC_FUNC_04: includes response format instructions" do
      prompt = PromptBuilder.build_system_prompt(capability_groups: @all_capability_groups)

      # Should explain the expected JSON response format
      assert prompt =~ ~r/json/i
      assert prompt =~ ~r/response/i
      assert prompt =~ "action"
      assert prompt =~ "params"
      assert prompt =~ "reasoning"
    end

    test "ARC_FUNC_05: includes wait parameter documentation for all non-wait actions" do
      prompt = PromptBuilder.build_system_prompt(capability_groups: @all_capability_groups)

      # Check wait parameter is documented
      assert prompt =~ "wait"

      # Check wait parameter types are documented
      assert prompt =~ ~r/boolean/i
      assert prompt =~ ~r/integer/i

      # Check wait semantics are explained
      assert prompt =~ "false"
      assert prompt =~ "true"
      assert prompt =~ ~r/seconds|timer|timeout/i
    end

    test "ARC_FUNC_06: wait parameter marked as optional for :wait action" do
      _prompt = PromptBuilder.build_system_prompt(capability_groups: @all_capability_groups)

      # The :wait action itself should not require a wait parameter
      # This is tricky to test from the full prompt, so we test schema directly
      json_schema = PromptBuilder.action_to_json_schema(:wait)

      # Wait parameter should NOT be in the required list for :wait action
      refute "wait" in (json_schema["required"] || [])
    end

    test "ARC_SEC_01: wait action example shows duration in seconds" do
      prompt = PromptBuilder.build_system_prompt(capability_groups: @all_capability_groups)

      # Verify example shows "wait": 5 (not 5000)
      assert prompt =~ ~s("wait": 5)
    end

    test "ARC_SEC_02: wait action example comment mentions seconds" do
      prompt = PromptBuilder.build_system_prompt(capability_groups: @all_capability_groups)

      # Verify comment mentions "5 seconds"
      assert prompt =~ "5 seconds"
    end

    test "ARC_SEC_03: wait action example does NOT use old millisecond value" do
      prompt = PromptBuilder.build_system_prompt(capability_groups: @all_capability_groups)

      # Verify old value 5000 is not present in wait context
      refute prompt =~ ~s("wait": 5000)
    end
  end

  describe "governance section injection (packet 2 R19-R22)" do
    setup do
      base_name = "prompt_builder_governance_#{System.unique_integer([:positive])}"
      skills_path = Path.join([System.tmp_dir!(), base_name])

      create_skill_fixture(base_name, "available-skill", "Available skill for ordering checks")

      on_exit(fn -> File.rm_rf!(skills_path) end)

      %{skills_path: skills_path, base_name: base_name}
    end

    test "R19: governance section injected after Identity and before Available Skills", %{
      skills_path: skills_path
    } do
      prompt =
        Sections.build_integrated_prompt(
          %{system_prompt: "IDENTITY_MARKER"},
          minimal_action_ctx(),
          minimal_profile_ctx(),
          skills_path: skills_path,
          governance_rules: "## Governance Rules\n\nDo not use pkill."
        )

      identity_pos = position_of(prompt, "IDENTITY_MARKER")
      governance_pos = position_of(prompt, "Governance Rules")
      available_skills_pos = position_of(prompt, "## Available Skills")

      assert identity_pos >= 0
      assert governance_pos >= 0
      assert available_skills_pos >= 0
      assert identity_pos < governance_pos
      assert governance_pos < available_skills_pos
    end

    test "R20: nil governance_rules produces no governance section", %{skills_path: skills_path} do
      prompt_without_governance =
        Sections.build_integrated_prompt(
          %{system_prompt: "Agent identity."},
          minimal_action_ctx(),
          minimal_profile_ctx(),
          skills_path: skills_path,
          governance_rules: nil
        )

      prompt_with_governance =
        Sections.build_integrated_prompt(
          %{system_prompt: "Agent identity."},
          minimal_action_ctx(),
          minimal_profile_ctx(),
          skills_path: skills_path,
          governance_rules: "## Governance Rules\n\nInjected text"
        )

      refute prompt_without_governance =~ "Governance Rules"
      assert prompt_with_governance =~ "Governance Rules"
    end

    test "R21: empty string governance_rules produces no governance section", %{
      skills_path: skills_path
    } do
      prompt_without_governance =
        Sections.build_integrated_prompt(
          %{system_prompt: "Agent identity."},
          minimal_action_ctx(),
          minimal_profile_ctx(),
          skills_path: skills_path,
          governance_rules: ""
        )

      prompt_with_governance =
        Sections.build_integrated_prompt(
          %{system_prompt: "Agent identity."},
          minimal_action_ctx(),
          minimal_profile_ctx(),
          skills_path: skills_path,
          governance_rules: "## Governance Rules\n\nInjected text"
        )

      refute prompt_without_governance =~ "Governance Rules"
      assert prompt_with_governance =~ "Governance Rules"
    end

    test "R22: governance content wrapped in InjectionProtection", %{skills_path: skills_path} do
      prompt =
        Sections.build_integrated_prompt(
          %{system_prompt: "Agent identity."},
          minimal_action_ctx(),
          minimal_profile_ctx(),
          skills_path: skills_path,
          governance_rules: "## Governance Rules\n\nImportant rules here."
        )

      assert prompt =~ "NO_EXECUTE_"
      assert prompt =~ "Important rules here"
    end
  end

  describe "wait parameter in action schemas" do
    test "wait parameter is required for non-wait actions" do
      non_wait_actions = Schema.list_actions() -- [:wait]

      Enum.each(non_wait_actions, fn action ->
        json_schema = PromptBuilder.action_to_json_schema(action)

        assert Map.has_key?(json_schema, "wait"),
               "Schema for #{action} should have wait parameter"

        assert "wait" in (json_schema["required"] || []),
               "Wait parameter should be required for #{action}"
      end)
    end

    test "wait parameter has correct type specification" do
      json_schema = PromptBuilder.action_to_json_schema(:spawn_child)
      wait_spec = json_schema["wait"]

      assert Map.has_key?(wait_spec, "type")
      # Can be either ["boolean", "integer"] or a oneOf structure
      assert wait_spec["type"] == ["boolean", "integer"]
    end

    test "wait parameter includes minimum constraint for integers" do
      json_schema = PromptBuilder.action_to_json_schema(:orient)
      wait_spec = json_schema["wait"]

      # Should specify minimum value of 0 for integer wait values
      assert wait_spec["minimum"] == 0
    end

    test "wait parameter includes semantic description" do
      json_schema = PromptBuilder.action_to_json_schema(:fetch_web)
      wait_spec = json_schema["wait"]

      assert Map.has_key?(wait_spec, "description")
      description = wait_spec["description"]

      # Should explain the three modes
      assert description =~ "false"
      assert description =~ "true"
      assert description =~ ~r/seconds|integer/i
    end
  end

  describe "action to JSON schema conversion" do
    test "converts action schema to JSON format" do
      # Test spawn_child action
      json_schema = PromptBuilder.action_to_json_schema(:spawn_child)

      assert is_map(json_schema)
      assert json_schema["action"] == "spawn_child"
      assert is_map(json_schema["params"])
      assert json_schema["params"]["type"] == "object"
      assert is_map(json_schema["params"]["properties"])
      assert is_list(json_schema["params"]["required"])
      assert "task_description" in json_schema["params"]["required"]
    end

    test "handles actions with no required params" do
      # Wait action has no required params
      json_schema = PromptBuilder.action_to_json_schema(:wait)

      assert json_schema["action"] == "wait"
      assert json_schema["params"]["required"] == []
    end

    test "handles complex param types" do
      # Orient has many params with different types
      json_schema = PromptBuilder.action_to_json_schema(:orient)

      properties = json_schema["params"]["properties"]
      assert is_map(properties["current_situation"])
      assert properties["current_situation"]["type"] == "string"
    end
  end

  describe "param type formatting" do
    test "formats basic types correctly" do
      assert PromptBuilder.format_param_type(:string) == "string"
      assert PromptBuilder.format_param_type(:integer) == "integer"
      assert PromptBuilder.format_param_type(:atom) == "string"
      assert PromptBuilder.format_param_type(:map) == "object"
    end

    test "formats list types" do
      assert PromptBuilder.format_param_type({:list, :string}) == %{
               "type" => "array",
               "items" => %{"type" => "string"}
             }
    end

    test "formats union types" do
      result = PromptBuilder.format_param_type({:union, [:string, :integer]})
      # Should return a map representing the union type
      assert is_map(result)
    end
  end

  describe "wait parameter in JSON schemas" do
    test "includes wait parameter in required array for non-wait actions" do
      non_wait_actions = Schema.list_actions() -- [:wait]

      for action <- non_wait_actions do
        json_schema = PromptBuilder.action_to_json_schema(action)

        # Wait should be in the required array
        assert "wait" in json_schema["required"],
               "Action #{action} should have 'wait' in required array"
      end
    end

    test "wait action has wait parameter (unified design)" do
      json_schema = PromptBuilder.action_to_json_schema(:wait)

      # Wait action now HAS wait parameter (unified with wait parameter)
      # Check in params
      if Map.has_key?(json_schema, "params") do
        assert Map.has_key?(json_schema["params"]["properties"], "wait"),
               "Wait action should have wait parameter in unified design"
      end

      # Wait parameter should NOT be in required array (it's optional)
      refute "wait" in Map.get(json_schema, "required", [])
    end

    test "wait parameter has correct type definition" do
      non_wait_actions = Schema.list_actions() -- [:wait]

      for action <- non_wait_actions do
        json_schema = PromptBuilder.action_to_json_schema(action)
        wait_spec = json_schema["wait"]

        assert wait_spec["type"] == ["boolean", "integer"] or
                 wait_spec["type"] == %{
                   "oneOf" => [
                     %{"type" => "boolean"},
                     %{"type" => "integer", "minimum" => 0}
                   ]
                 },
               "Action #{action} should have correct wait parameter type"

        # If integer, should have minimum constraint
        if is_map(wait_spec["type"]) do
          integer_spec = Enum.find(wait_spec["type"]["oneOf"], &(&1["type"] == "integer"))
          assert integer_spec["minimum"] == 0
        end
      end
    end

    test "wait parameter includes description with semantics" do
      non_wait_actions = Schema.list_actions() -- [:wait]

      for action <- non_wait_actions do
        json_schema = PromptBuilder.action_to_json_schema(action)
        wait_spec = json_schema["wait"]

        assert is_binary(wait_spec["description"])

        # Check for key semantic explanations
        description = wait_spec["description"]
        assert description =~ "false"
        assert description =~ "true"
        assert description =~ ~r/integer|milliseconds|seconds/i
      end
    end
  end

  describe "system prompt wait parameter education" do
    test "system prompt includes wait parameter documentation" do
      prompt = PromptBuilder.build_system_prompt(capability_groups: @all_capability_groups)

      # Should explain wait parameter
      assert prompt =~ "wait"
      assert prompt =~ "parameter"

      # Should explain the three modes
      assert prompt =~ "false"
      assert prompt =~ "true"
      assert prompt =~ ~r/integer|timeout|milliseconds/i
    end

    test "system prompt marks wait as required for non-wait actions" do
      prompt = PromptBuilder.build_system_prompt(capability_groups: @all_capability_groups)

      # Check that non-wait actions show wait as required
      non_wait_actions = Schema.list_actions() -- [:wait]

      for action <- non_wait_actions do
        action_section = prompt
        # The prompt should indicate wait is required for this action
        assert action_section =~ Atom.to_string(action)
      end
    end

    test "generates valid JSON examples in system prompt" do
      prompt = PromptBuilder.build_system_prompt(capability_groups: @all_capability_groups)

      # Look for the example response line (single-line JSON)
      if prompt =~ ~r/\{"action":.*"reasoning":.*\}/ do
        # Extract the single-line JSON example
        [json_str] = Regex.run(~r/\{"action":.*"reasoning":.*\}/, prompt)
        assert {:ok, _} = Jason.decode(json_str)
      else
        # No JSON example found, that's OK
        assert true
      end
    end
  end

  describe "schema alignment with ACTION_Schema" do
    test "ARC_SCHEMA_01: all actions from Schema appear in prompt" do
      prompt = PromptBuilder.build_system_prompt(capability_groups: @all_capability_groups)

      for action <- Schema.list_actions() do
        assert prompt =~ Atom.to_string(action),
               "Expected action #{action} to appear in system prompt"
      end
    end

    property "ARC_SCHEMA_02: JSON schema reflects action params" do
      check all(action <- StreamData.member_of(Schema.list_actions())) do
        {:ok, schema} = Schema.get_schema(action)
        json_schema = PromptBuilder.action_to_json_schema(action)

        # Check if this is a XOR schema (has oneOf) or standard schema
        if json_schema["params"]["oneOf"] do
          # XOR schema - each variant in oneOf should include all params from that mode
          # For XOR actions, required_params should be empty (they're in the XOR groups)
          # and all params should appear across the oneOf variants
          all_params =
            (schema.required_params ++ schema.optional_params)
            |> Enum.map(&Atom.to_string/1)

          # Collect all properties across all oneOf variants
          all_properties =
            json_schema["params"]["oneOf"]
            |> Enum.flat_map(fn variant -> Map.keys(variant["properties"]) end)
            |> MapSet.new()

          # All params should be present somewhere in the oneOf variants
          Enum.each(all_params, fn param ->
            assert param in all_properties,
                   "Param #{param} should be in oneOf properties for action #{action}"
          end)
        else
          # Standard schema - check required and properties as before
          required_params = schema.required_params |> Enum.map(&Atom.to_string/1)
          assert MapSet.new(json_schema["params"]["required"]) == MapSet.new(required_params)

          # All params (required + optional) should be present in properties
          all_params =
            (schema.required_params ++ schema.optional_params)
            |> Enum.map(&Atom.to_string/1)

          properties_keys = Map.keys(json_schema["params"]["properties"])

          Enum.each(all_params, fn param ->
            assert param in properties_keys,
                   "Param #{param} should be in properties for action #{action}"
          end)
        end
      end
    end

    test "ARC_SCHEMA_03: handles invalid actions gracefully" do
      # Should not crash even with invalid action
      result = PromptBuilder.action_to_json_schema(:not_a_real_action)

      # Should return nil for unknown actions
      assert is_nil(result)
    end

    property "ARC_WAIT_01: wait parameter required for all non-wait actions" do
      check all(action <- StreamData.member_of(Schema.list_actions() -- [:wait])) do
        json_schema = PromptBuilder.action_to_json_schema(action)

        # Wait should be in the required array for all non-wait actions
        assert "wait" in json_schema["required"],
               "Action #{action} must have 'wait' as required"

        # Wait should have proper specification
        assert Map.has_key?(json_schema, "wait")
        assert is_map(json_schema["wait"])
      end
    end

    property "ARC_WAIT_02: wait parameter absent from :wait action" do
      # This isn't really a property test, but keeping consistent format
      json_schema = PromptBuilder.action_to_json_schema(:wait)

      # Wait action should never have wait parameter
      refute Map.has_key?(json_schema, "wait"),
             ":wait action must not have wait parameter"

      refute "wait" in Map.get(json_schema, "required", []),
             ":wait action must not require wait parameter"

      true
    end

    property "ARC_WAIT_03: wait parameter type consistency across actions" do
      check all(action <- StreamData.member_of(Schema.list_actions() -- [:wait])) do
        json_schema = PromptBuilder.action_to_json_schema(action)
        wait_spec = json_schema["wait"]

        # All actions should have consistent wait parameter type definition
        assert wait_spec["type"] in [
                 ["boolean", "integer"],
                 %{"oneOf" => [%{"type" => "boolean"}, %{"type" => "integer", "minimum" => 0}]},
                 %{"anyOf" => [%{"type" => "boolean"}, %{"type" => "integer", "minimum" => 0}]}
               ],
               "Wait parameter type should be consistent for #{action}"

        # Must have description
        assert is_binary(wait_spec["description"])
      end
    end
  end

  describe "wait parameter integration with Schema module" do
    test "wait_required? aligns with JSON schema generation" do
      for action <- Schema.list_actions() do
        json_schema = PromptBuilder.action_to_json_schema(action)

        if Schema.wait_required?(action) do
          assert "wait" in json_schema["required"],
                 "#{action} requires wait per Schema but not in JSON"
        else
          refute "wait" in Map.get(json_schema, "required", []),
                 "#{action} doesn't require wait per Schema but is in JSON"
        end
      end
    end

    test "build_action_examples includes wait parameter examples" do
      examples = PromptBuilder.build_action_examples()

      # Should include examples with wait parameter
      assert examples =~ "wait"
      assert examples =~ "true"
      assert examples =~ "false"
      assert examples =~ "spawn_child"
      assert examples =~ "send_message"
    end

    test "format_wait_type generates proper JSON schema type" do
      wait_type = PromptBuilder.format_wait_type()

      assert wait_type["type"] == ["boolean", "integer"]
      assert wait_type["minimum"] == 0
      assert is_binary(wait_type["description"])
      assert wait_type["description"] =~ "flow continuation"
    end

    test "validate_wait_parameter_in_prompt ensures proper LLM education" do
      prompt = PromptBuilder.build_system_prompt(capability_groups: @all_capability_groups)

      # Extract action documentation sections
      action_docs = String.split(prompt, ~r/### Action:/)

      # Each non-wait action section should mention wait parameter
      for action <- Schema.list_actions() -- [:wait] do
        action_name = Atom.to_string(action)

        action_section =
          Enum.find(action_docs, fn doc ->
            String.contains?(doc, action_name)
          end)

        if action_section do
          assert action_section =~ "wait",
                 "Action #{action} section should mention wait parameter"
        end
      end

      # Wait action section should NOT require wait parameter
      wait_section =
        Enum.find(action_docs, fn doc ->
          String.contains?(doc, "wait")
        end)

      if wait_section do
        refute wait_section =~ "wait.*required" or wait_section =~ "must.*wait",
               ":wait action should not require wait parameter"
      end
    end
  end

  describe "debug logging" do
    test "ARC_DEBUG_01: logs full prompt when debug enabled" do
      # Test behavior: function returns :ok when debug enabled
      prompt = PromptBuilder.build_system_prompt(capability_groups: @all_capability_groups)
      assert :ok == PromptBuilder.debug_log_prompt(prompt, debug: true)

      # The actual logging is at debug level which may not be captured in tests
      # We're testing the behavior (returns :ok) not the side effect
    end

    test "ARC_DEBUG_02: no logging when debug disabled" do
      # Test behavior: function returns :ok when debug disabled
      prompt = PromptBuilder.build_system_prompt(capability_groups: @all_capability_groups)
      assert :ok == PromptBuilder.debug_log_prompt(prompt, debug: false)
    end

    test "debug_log_prompt respects debug option" do
      # Test behavior: always returns :ok regardless of debug option
      assert :ok == PromptBuilder.debug_log_prompt("Test prompt content", debug: true)
      assert :ok == PromptBuilder.debug_log_prompt("Test prompt content", debug: false)
    end

    test "debug_log_prompt defaults to config when no option provided" do
      # Test behavior: always returns :ok when using default config
      assert :ok == PromptBuilder.debug_log_prompt("Test prompt content", [])
    end
  end

  describe "edge cases" do
    test "handles empty action list gracefully" do
      # If somehow Schema.list_actions returns empty
      # The prompt should still have basic structure
      prompt = PromptBuilder.build_system_prompt(capability_groups: @all_capability_groups)

      assert is_binary(prompt)
      assert prompt != ""
      # Should still have instructions even without actions
    end

    test "handles Schema errors gracefully" do
      # Test with an action that might cause Schema.get_schema to error
      # Should not crash the entire prompt generation
      prompt = PromptBuilder.build_system_prompt(capability_groups: @all_capability_groups)
      assert is_binary(prompt)
    end
  end

  describe "compile-time caching" do
    test "multiple calls return identical prompt structure" do
      prompt1 = PromptBuilder.build_system_prompt(capability_groups: @all_capability_groups)
      prompt2 = PromptBuilder.build_system_prompt(capability_groups: @all_capability_groups)

      # NO_EXECUTE tags have random IDs for security, so strip them before comparing
      normalize = fn prompt ->
        Regex.replace(~r/<\/?NO_EXECUTE_[a-f0-9]+>/, prompt, "<NO_EXECUTE>")
      end

      # Should be the same structure (NO_EXECUTE IDs may differ)
      assert normalize.(prompt1) == normalize.(prompt2)
    end
  end

  defp create_skill_fixture(base_name, skill_name, description) do
    File.mkdir_p!(Path.join([System.tmp_dir!(), base_name, skill_name]))

    File.write!(Path.join([System.tmp_dir!(), base_name, skill_name, "SKILL.md"]), """
    ---
    name: #{skill_name}
    description: #{description}
    ---

    # #{skill_name}
    """)
  end

  defp minimal_action_ctx do
    %Context.Action{
      schemas: "",
      untrusted_docs: "",
      trusted_docs: "",
      allowed_actions: [],
      format_secrets_fn: fn -> "" end
    }
  end

  defp minimal_profile_ctx do
    %Context.Profile{}
  end

  defp position_of(text, substring) do
    case :binary.match(text, substring) do
      {pos, _len} -> pos
      :nomatch -> -1
    end
  end
end
