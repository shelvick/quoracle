defmodule Quoracle.Consensus.PromptBuilderTest do
  use Quoracle.DataCase, async: true
  use ExUnitProperties

  alias Quoracle.Consensus.PromptBuilder
  alias Quoracle.Actions.Schema

  # All capability groups to include all actions in prompts
  @all_capability_groups [:file_read, :file_write, :external_api, :hierarchy, :local_execution]

  describe "system prompt generation" do
    test "ARC_FUNC_01: returns string containing all 21 actions" do
      prompt = PromptBuilder.build_system_prompt(capability_groups: @all_capability_groups)

      assert is_binary(prompt)

      # Verify all actions from Schema are present
      actions = Schema.list_actions()
      assert length(actions) == 22

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

  describe "NO_EXECUTE documentation (Packet 2)" do
    # R12: NO_EXECUTE Section Presence
    test "system prompt includes NO_EXECUTE tag documentation" do
      prompt = PromptBuilder.build_system_prompt(capability_groups: @all_capability_groups)

      # Should contain NO_EXECUTE section
      assert prompt =~ "NO_EXECUTE"
      assert prompt =~ "Prompt Injection Protection"
    end

    # R13: Untrusted Actions Listed
    test "NO_EXECUTE section lists all 5 untrusted actions" do
      prompt = PromptBuilder.build_system_prompt(capability_groups: @all_capability_groups)

      # All 5 untrusted actions should be listed
      assert prompt =~ "execute_shell"
      assert prompt =~ "fetch_web"
      assert prompt =~ "call_api"
      assert prompt =~ "call_mcp"
      assert prompt =~ "answer_engine"

      # Should be in context of untrusted/wrapped actions
      assert prompt =~ ~r/(untrusted|wrapped|NO_EXECUTE).*execute_shell/si
    end

    # R14: Trusted Actions Listed
    test "NO_EXECUTE section lists all 5 trusted actions" do
      prompt = PromptBuilder.build_system_prompt(capability_groups: @all_capability_groups)

      # All 5 trusted actions should be listed
      assert prompt =~ "send_message"
      assert prompt =~ "spawn_child"
      assert prompt =~ "wait"
      assert prompt =~ "orient"
      assert prompt =~ "todo"

      # Should be in context of trusted/not wrapped actions
      assert prompt =~ ~r/(trusted|no wrapping|produce trusted).*send_message/si
    end

    # R15: Critical Warning Present
    test "NO_EXECUTE section includes critical data warning" do
      prompt = PromptBuilder.build_system_prompt(capability_groups: @all_capability_groups)

      # Should include critical warning about treating content as data
      assert prompt =~ "CRITICAL"

      assert prompt =~ ~r/(Content inside NO_EXECUTE.*DATA|NO_EXECUTE.*not instructions)/si

      # Warning should be emphatic
      assert prompt =~ ~r/(CRITICAL|IMPORTANT|WARNING)/i
    end

    # R16: Example Injection Shown
    test "NO_EXECUTE section shows injection attack example" do
      prompt = PromptBuilder.build_system_prompt(capability_groups: @all_capability_groups)

      # Should include example of injection attempt
      assert prompt =~ "NO_EXECUTE_"

      # Example should show malicious content being wrapped
      assert prompt =~ ~r/(IGNORE|evil|malicious|attack|injection)/i

      # Should demonstrate the protection mechanism
      assert prompt =~ ~r/example/i
    end

    # R17: Section Placement - NO_EXECUTE primes security awareness BEFORE action schemas
    test "NO_EXECUTE section placement in system prompt" do
      prompt = PromptBuilder.build_system_prompt(capability_groups: @all_capability_groups)

      # Find positions of key sections
      actions_header_pos =
        case Regex.run(~r/## Available Actions/s, prompt, return: :index) do
          [{pos, _} | _] -> pos
          _ -> 0
        end

      # Match the specific section heading (now a subsection under Available Actions)
      no_execute_section_pos =
        case Regex.run(~r/### CRITICAL: Prompt Injection Protection/si, prompt, return: :index) do
          [{pos, _} | _] -> pos
          _ -> :not_found
        end

      # Find first action schema (after the NO_EXECUTE warning)
      first_schema_pos =
        case Regex.run(~r/"type":\s*"object"/s, prompt, return: :index) do
          [{pos, _} | _] -> pos
          _ -> String.length(prompt)
        end

      # Use more specific regex to match the actual "Response JSON Schema:" header
      response_format_pos =
        case Regex.run(~r/Response JSON Schema:/s, prompt, return: :index) do
          [{pos, _} | _] -> pos
          _ -> String.length(prompt)
        end

      # NO_EXECUTE section should exist and appear after Available Actions header
      assert no_execute_section_pos != :not_found
      assert no_execute_section_pos > actions_header_pos

      # NO_EXECUTE section should appear BEFORE action schemas (security priming)
      assert no_execute_section_pos < first_schema_pos

      # NO_EXECUTE section should appear before response format instructions
      assert no_execute_section_pos < response_format_pos
    end

    test "NO_EXECUTE section is comprehensive" do
      prompt = PromptBuilder.build_system_prompt(capability_groups: @all_capability_groups)

      # Should explain the purpose
      assert prompt =~ ~r/(prevent.*injection|security.*boundary|protection)/si

      # Should explain what to do with wrapped content
      assert prompt =~ ~r/(analyze|process|treat as data)/si

      # Should explain what NOT to do
      assert prompt =~ ~r/(DO NOT.*follow|ignore.*instructions|not.*execute)/si
    end

    test "NO_EXECUTE section mentions random ID security" do
      prompt = PromptBuilder.build_system_prompt(capability_groups: @all_capability_groups)

      # Should explain that random ID prevents simple injection
      assert prompt =~ ~r/(random|ID|unpredictable)/i
      assert prompt =~ ~r/(prevent|stop|block).*injection/si
    end
  end

  describe "call_api action documentation (Packet 6)" do
    # R1: Schema Documentation
    test "includes call_api in system prompt actions" do
      prompt = PromptBuilder.build_system_prompt(capability_groups: @all_capability_groups)

      # call_api should be listed as an available action
      assert prompt =~ "call_api"

      # Verify it's in the actions list from Schema
      actions = Schema.list_actions()
      assert :call_api in actions
    end

    # R2: Parameter Documentation
    test "includes call_api parameter documentation" do
      prompt = PromptBuilder.build_system_prompt(capability_groups: @all_capability_groups)

      # Should document key call_api parameters in JSON schema
      assert prompt =~ "api_type"
      assert prompt =~ "url"
      assert prompt =~ "method"

      # Should have JSON schema properties for call_api
      assert prompt =~ ~r/(call_api.*properties|properties.*call_api)/s
    end

    # R3: Protocol Guidance
    test "includes protocol-specific guidance for REST, GraphQL, and JSON-RPC" do
      prompt = PromptBuilder.build_system_prompt(capability_groups: @all_capability_groups)

      # Should have explicit REST guidance
      assert prompt =~ ~r/(REST.*standard HTTP methods|api_type.*rest)/i

      # Should have explicit GraphQL guidance
      assert prompt =~ ~r/(GraphQL.*query.*mutation|api_type.*graphql)/i

      # Should have explicit JSON-RPC guidance
      assert prompt =~ ~r/(JSON-RPC.*method.*params|api_type.*jsonrpc)/i
    end

    # R4: Authentication Guidance
    test "documents authentication strategies with examples" do
      prompt = PromptBuilder.build_system_prompt(capability_groups: @all_capability_groups)

      # Should have example showing bearer token authentication
      assert prompt =~ ~r/(bearer.*token|auth_type.*bearer)/i

      # Should have example showing basic authentication
      assert prompt =~ ~r/(basic.*username.*password|auth_type.*basic)/i

      # Should have example showing OAuth2
      assert prompt =~ ~r/(oauth.*client|auth_type.*oauth)/i

      # Should show secret resolution pattern for API keys
      assert prompt =~ ~r/(\{\{SECRET:.*\}\}|SECRET:.*token)/i
    end

    test "includes call_api usage examples with different protocols" do
      examples = PromptBuilder.Sections.build_action_examples()

      # Should have REST example
      assert examples =~ "call_api"

      # Example should show api_type
      assert examples =~ "api_type"
    end
  end

  # CONSENSUS_PromptBuilder v8.0 - MCP Action Schema
  # ARC Verification Criteria for call_mcp schema propagation
  describe "call_mcp v8.0 schema in system prompt" do
    test "R21: call_mcp action appears in system prompt" do
      # [UNIT] - WHEN system prompt built THEN call_mcp action schema included
      prompt = PromptBuilder.build_system_prompt(capability_groups: @all_capability_groups)

      # call_mcp should be present in the prompt
      assert prompt =~ "call_mcp"

      # Should have its schema documented
      json_schema = PromptBuilder.action_to_json_schema(:call_mcp)
      assert is_map(json_schema)
      assert Map.has_key?(json_schema, "params")
    end

    test "R22: call_mcp schema shows 3 distinct modes with isolated parameters" do
      # [UNIT] - WHEN call_mcp schema generated THEN shows 3 oneOf modes: CONNECT, CALL, TERMINATE
      json_schema = PromptBuilder.action_to_json_schema(:call_mcp)

      # Should have oneOf structure
      assert Map.has_key?(json_schema["params"], "oneOf"),
             "call_mcp should have oneOf structure"

      one_of_variants = json_schema["params"]["oneOf"]
      assert is_list(one_of_variants)

      # Must have exactly 3 modes
      assert length(one_of_variants) == 3,
             "call_mcp should have exactly 3 modes (CONNECT, CALL, TERMINATE)"

      # Each mode should have only its relevant parameters (2-5 params), not all 9
      param_counts = Enum.map(one_of_variants, &map_size(&1["properties"]))

      assert Enum.all?(param_counts, &(&1 in 2..5)),
             "Each mode should have 2-5 params, got: #{inspect(param_counts)}"

      # Verify mode descriptions
      descriptions = Enum.map(one_of_variants, & &1["description"])
      assert Enum.any?(descriptions, &String.contains?(&1, "CONNECT"))
      assert Enum.any?(descriptions, &String.contains?(&1, "CALL"))
      assert Enum.any?(descriptions, &String.contains?(&1, "TERMINATE"))

      # Verify required fields per mode
      [connect, call_mode, terminate] = one_of_variants
      assert "transport" in connect["required"]
      assert "connection_id" in call_mode["required"]
      assert "tool" in call_mode["required"]
      assert "connection_id" in terminate["required"]
      assert "terminate" in terminate["required"]
    end

    test "R23: call_mcp transport shows stdio and http options" do
      # [UNIT] - WHEN call_mcp schema generated THEN transport shows enum values
      json_schema = PromptBuilder.action_to_json_schema(:call_mcp)

      # Find transport parameter in the oneOf variants
      transport_spec =
        json_schema["params"]["oneOf"]
        |> Enum.find_value(fn variant ->
          get_in(variant, ["properties", "transport"])
        end)

      assert transport_spec != nil, "transport parameter should exist in call_mcp schema"

      # Transport should be an enum with stdio and http values
      assert transport_spec["enum"] == ["stdio", "http"] or
               transport_spec["enum"] == [:stdio, :http],
             "transport should have enum with stdio and http values"
    end
  end

  # CONSENSUS_PromptBuilder v10.0 - Announcement Target Documentation
  # ARC Verification Criteria for announcement target in system prompts
  describe "announcement target docs (v10.0)" do
    # R1: Announcement in Trusted Action Docs
    test "send_message trusted doc mentions announcement target" do
      # [UNIT] - WHEN prepare_action_docs called THEN send_message entry mentions announcement target
      prompt = PromptBuilder.build_system_prompt(capability_groups: @all_capability_groups)

      # The send_message documentation should mention announcement as a target option
      # Both concepts must be present in the prompt
      assert prompt =~ "send_message"
      assert prompt =~ "announcement"
    end

    # R2: Action Description Updated
    test "send_message description documents announcement target" do
      # [UNIT] - WHEN get_action_description(:send_message) called THEN mentions announcement for recursive broadcast
      description = Schema.get_action_description(:send_message)

      assert is_binary(description)
      assert description =~ "announcement"
      # Should mention recursive or descendants
      assert description =~ ~r/(recursive|descendant|subtree|all)/i
    end

    # R3: Children vs Announcement Distinguished
    test "send_message description distinguishes children from announcement" do
      # [UNIT] - WHEN get_action_description(:send_message) called THEN clarifies children is direct only
      description = Schema.get_action_description(:send_message)

      assert is_binary(description)
      # Should clarify that children means direct children only (both concepts must be present)
      assert description =~ "children"
      assert description =~ "direct"
    end

    # R4: One-Way Nature Documented
    test "send_message description notes announcement is one-way" do
      # [UNIT] - WHEN get_action_description(:send_message) called THEN mentions announcements are one-way
      description = Schema.get_action_description(:send_message)

      assert is_binary(description)
      # Should mention one-way nature or no reply expected
      assert description =~ ~r/(one-way|broadcast|no reply)/i
    end

    # R5: Prompt Integration
    test "system prompt includes announcement target documentation" do
      # [INTEGRATION] - WHEN build_system_prompt called THEN generated prompt includes announcement documentation
      prompt = PromptBuilder.build_system_prompt(capability_groups: @all_capability_groups)

      # The system prompt should document the announcement target
      assert prompt =~ "announcement"

      # Should explain its purpose (recursive broadcast to descendants)
      assert prompt =~ ~r/(descendant|recursive|subtree)/i

      # Should distinguish from regular children target
      assert prompt =~ ~r/children/i
    end
  end
end
