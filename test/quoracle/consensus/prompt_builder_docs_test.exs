defmodule Quoracle.Consensus.PromptBuilderDocsTest do
  @moduledoc """
  Split from PromptBuilderTest for better parallelism.
  Tests action documentation in system prompts: NO_EXECUTE,
  call_api, call_mcp, and announcement target docs.
  """

  use ExUnit.Case, async: true

  alias Quoracle.Consensus.PromptBuilder
  alias Quoracle.Actions.Schema

  @all_capability_groups [:file_read, :file_write, :external_api, :hierarchy, :local_execution]

  describe "NO_EXECUTE documentation (Packet 2)" do
    test "system prompt includes NO_EXECUTE tag documentation" do
      prompt = PromptBuilder.build_system_prompt(capability_groups: @all_capability_groups)

      assert prompt =~ "NO_EXECUTE"
      assert prompt =~ "Prompt Injection Protection"
    end

    test "NO_EXECUTE section lists all 5 untrusted actions" do
      prompt = PromptBuilder.build_system_prompt(capability_groups: @all_capability_groups)

      assert prompt =~ "execute_shell"
      assert prompt =~ "fetch_web"
      assert prompt =~ "call_api"
      assert prompt =~ "call_mcp"
      assert prompt =~ "answer_engine"

      assert prompt =~ ~r/(untrusted|wrapped|NO_EXECUTE).*execute_shell/si
    end

    test "NO_EXECUTE section lists all 5 trusted actions" do
      prompt = PromptBuilder.build_system_prompt(capability_groups: @all_capability_groups)

      assert prompt =~ "send_message"
      assert prompt =~ "spawn_child"
      assert prompt =~ "wait"
      assert prompt =~ "orient"
      assert prompt =~ "todo"

      assert prompt =~ ~r/(trusted|no wrapping|produce trusted).*send_message/si
    end

    test "NO_EXECUTE section includes critical data warning" do
      prompt = PromptBuilder.build_system_prompt(capability_groups: @all_capability_groups)

      assert prompt =~ "CRITICAL"

      assert prompt =~ ~r/(Content inside NO_EXECUTE.*DATA|NO_EXECUTE.*not instructions)/si

      assert prompt =~ ~r/(CRITICAL|IMPORTANT|WARNING)/i
    end

    test "NO_EXECUTE section shows injection attack example" do
      prompt = PromptBuilder.build_system_prompt(capability_groups: @all_capability_groups)

      assert prompt =~ "NO_EXECUTE_"

      assert prompt =~ ~r/(IGNORE|evil|malicious|attack|injection)/i

      assert prompt =~ ~r/example/i
    end

    test "NO_EXECUTE section placement in system prompt" do
      prompt = PromptBuilder.build_system_prompt(capability_groups: @all_capability_groups)

      actions_header_pos =
        case Regex.run(~r/## Available Actions/s, prompt, return: :index) do
          [{pos, _} | _] -> pos
          _ -> 0
        end

      no_execute_section_pos =
        case Regex.run(~r/### CRITICAL: Prompt Injection Protection/si, prompt, return: :index) do
          [{pos, _} | _] -> pos
          _ -> :not_found
        end

      first_schema_pos =
        case Regex.run(~r/"type":\s*"object"/s, prompt, return: :index) do
          [{pos, _} | _] -> pos
          _ -> String.length(prompt)
        end

      response_format_pos =
        case Regex.run(~r/Response JSON Schema:/s, prompt, return: :index) do
          [{pos, _} | _] -> pos
          _ -> String.length(prompt)
        end

      assert no_execute_section_pos != :not_found
      assert no_execute_section_pos > actions_header_pos

      assert no_execute_section_pos < first_schema_pos

      assert no_execute_section_pos < response_format_pos
    end

    test "NO_EXECUTE section is comprehensive" do
      prompt = PromptBuilder.build_system_prompt(capability_groups: @all_capability_groups)

      assert prompt =~ ~r/(prevent.*injection|security.*boundary|protection)/si

      assert prompt =~ ~r/(analyze|process|treat as data)/si

      assert prompt =~ ~r/(DO NOT.*follow|ignore.*instructions|not.*execute)/si
    end

    test "NO_EXECUTE section mentions random ID security" do
      prompt = PromptBuilder.build_system_prompt(capability_groups: @all_capability_groups)

      assert prompt =~ ~r/(random|ID|unpredictable)/i
      assert prompt =~ ~r/(prevent|stop|block).*injection/si
    end
  end

  describe "call_api action documentation (Packet 6)" do
    test "includes call_api in system prompt actions" do
      prompt = PromptBuilder.build_system_prompt(capability_groups: @all_capability_groups)

      assert prompt =~ "call_api"

      actions = Schema.list_actions()
      assert :call_api in actions
    end

    test "includes call_api parameter documentation" do
      prompt = PromptBuilder.build_system_prompt(capability_groups: @all_capability_groups)

      assert prompt =~ "api_type"
      assert prompt =~ "url"
      assert prompt =~ "method"

      assert prompt =~ ~r/(call_api.*properties|properties.*call_api)/s
    end

    test "includes protocol-specific guidance for REST, GraphQL, and JSON-RPC" do
      prompt = PromptBuilder.build_system_prompt(capability_groups: @all_capability_groups)

      assert prompt =~ ~r/(REST.*standard HTTP methods|api_type.*rest)/i

      assert prompt =~ ~r/(GraphQL.*query.*mutation|api_type.*graphql)/i

      assert prompt =~ ~r/(JSON-RPC.*method.*params|api_type.*jsonrpc)/i
    end

    test "documents authentication strategies with examples" do
      prompt = PromptBuilder.build_system_prompt(capability_groups: @all_capability_groups)

      assert prompt =~ ~r/(bearer.*token|auth_type.*bearer)/i

      assert prompt =~ ~r/(basic.*username.*password|auth_type.*basic)/i

      assert prompt =~ ~r/(oauth.*client|auth_type.*oauth)/i

      assert prompt =~ ~r/(\{\{SECRET:.*\}\}|SECRET:.*token)/i
    end

    test "includes call_api usage examples with different protocols" do
      examples = PromptBuilder.Sections.build_action_examples()

      assert examples =~ "call_api"

      assert examples =~ "api_type"
    end
  end

  describe "call_mcp v8.0 schema in system prompt" do
    test "R21: call_mcp action appears in system prompt" do
      prompt = PromptBuilder.build_system_prompt(capability_groups: @all_capability_groups)

      assert prompt =~ "call_mcp"

      json_schema = PromptBuilder.action_to_json_schema(:call_mcp)
      assert is_map(json_schema)
      assert Map.has_key?(json_schema, "params")
    end

    test "R22: call_mcp schema shows 3 distinct modes with isolated parameters" do
      json_schema = PromptBuilder.action_to_json_schema(:call_mcp)

      assert Map.has_key?(json_schema["params"], "oneOf"),
             "call_mcp should have oneOf structure"

      one_of_variants = json_schema["params"]["oneOf"]
      assert is_list(one_of_variants)

      assert length(one_of_variants) == 3,
             "call_mcp should have exactly 3 modes (CONNECT, CALL, TERMINATE)"

      param_counts = Enum.map(one_of_variants, &map_size(&1["properties"]))

      assert Enum.all?(param_counts, &(&1 in 2..5)),
             "Each mode should have 2-5 params, got: #{inspect(param_counts)}"

      descriptions = Enum.map(one_of_variants, & &1["description"])
      assert Enum.any?(descriptions, &String.contains?(&1, "CONNECT"))
      assert Enum.any?(descriptions, &String.contains?(&1, "CALL"))
      assert Enum.any?(descriptions, &String.contains?(&1, "TERMINATE"))

      [connect, call_mode, terminate] = one_of_variants
      assert "transport" in connect["required"]
      assert "connection_id" in call_mode["required"]
      assert "tool" in call_mode["required"]
      assert "connection_id" in terminate["required"]
      assert "terminate" in terminate["required"]
    end

    test "R23: call_mcp transport shows stdio and http options" do
      json_schema = PromptBuilder.action_to_json_schema(:call_mcp)

      transport_spec =
        json_schema["params"]["oneOf"]
        |> Enum.find_value(fn variant ->
          get_in(variant, ["properties", "transport"])
        end)

      assert transport_spec != nil, "transport parameter should exist in call_mcp schema"

      assert transport_spec["enum"] == ["stdio", "http"] or
               transport_spec["enum"] == [:stdio, :http],
             "transport should have enum with stdio and http values"
    end
  end

  describe "announcement target docs (v10.0)" do
    test "send_message trusted doc mentions announcement target" do
      prompt = PromptBuilder.build_system_prompt(capability_groups: @all_capability_groups)

      assert prompt =~ "send_message"
      assert prompt =~ "announcement"
    end

    test "send_message description documents announcement target" do
      description = Schema.get_action_description(:send_message)

      assert is_binary(description)
      assert description =~ "announcement"
      assert description =~ ~r/(recursive|descendant|subtree|all)/i
    end

    test "send_message description distinguishes children from announcement" do
      description = Schema.get_action_description(:send_message)

      assert is_binary(description)
      assert description =~ "children"
      assert description =~ "direct"
    end

    test "send_message description notes announcement is one-way" do
      description = Schema.get_action_description(:send_message)

      assert is_binary(description)
      assert description =~ ~r/(one-way|broadcast|no reply)/i
    end

    test "system prompt includes announcement target documentation" do
      prompt = PromptBuilder.build_system_prompt(capability_groups: @all_capability_groups)

      assert prompt =~ "announcement"

      assert prompt =~ ~r/(descendant|recursive|subtree)/i

      assert prompt =~ ~r/children/i
    end
  end
end
