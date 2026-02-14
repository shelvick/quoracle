defmodule Quoracle.Consensus.PromptBuilder.SchemaFormatter do
  @moduledoc """
  Converts action schemas to JSON Schema format for LLM consumption.

  Handles type conversion and nested structures.
  Provides pure transformation functions from Elixir schema definitions to
  JSON Schema format compatible with OpenAI, Anthropic, and other LLM providers.

  Note: The 'wait' parameter is a response-level flow control directive, not an
  action parameter. It appears in the top-level response schema but NOT in
  individual action parameter schemas.
  """

  alias Quoracle.Actions.Schema

  @doc """
  Converts an action schema to JSON schema format.
  Returns a map representing the JSON schema for the action.

  For actions with xor_params (mutually exclusive parameter groups),
  generates a oneOf structure with separate schemas for each mode.

  ## Options
    * `:profile_names` - List of profile names to inject as enum for spawn_child profile param
  """
  @spec action_to_json_schema(atom(), keyword()) :: map() | nil
  def action_to_json_schema(action, opts \\ []) do
    case Schema.get_schema(action) do
      {:ok, schema} ->
        # Check if this action has XOR params (mutually exclusive parameter groups)
        xor_params = Map.get(schema, :xor_params, [])

        if xor_params != [] do
          build_xor_schema(action, schema, xor_params)
        else
          build_standard_schema(action, schema, opts)
        end

      {:error, _} ->
        nil
    end
  end

  # Build standard schema (no mutually exclusive params)
  defp build_standard_schema(action, schema, opts) do
    # Get param_descriptions map if it exists
    param_descriptions = Map.get(schema, :param_descriptions, %{})
    profile_names = Keyword.get(opts, :profile_names, [])

    properties =
      (schema.required_params ++ schema.optional_params)
      |> Enum.map(fn param ->
        type = Map.get(schema.param_types, param, :string)
        description = Map.get(param_descriptions, param)

        # Special handling for send_message 'to' parameter to provide valid values
        formatted_type =
          cond do
            action == :send_message and param == :to ->
              %{
                "oneOf" => [
                  %{
                    "type" => "string",
                    "enum" => ["parent", "children", "announcement"],
                    "description" =>
                      "'parent' (your creator - status/results go here), 'children' (direct only), 'announcement' (broadcast directives/corrections downward - NOT for status updates)"
                  },
                  %{
                    "type" => "array",
                    "items" => %{"type" => "string"},
                    "description" => "List of specific agent IDs"
                  }
                ]
              }

            # NEW: spawn_child 'profile' enum injection
            action == :spawn_child and param == :profile and profile_names != [] ->
              base = %{"type" => "string", "enum" => profile_names}
              if description, do: Map.put(base, "description", description), else: base

            true ->
              formatted = format_param_type(type)
              # Wrap simple string types, but not complex maps
              base_schema = if is_binary(formatted), do: %{"type" => formatted}, else: formatted

              # Add description if available
              if description do
                Map.put(base_schema, "description", description)
              else
                base_schema
              end
          end

        {Atom.to_string(param), formatted_type}
      end)
      |> Enum.into(%{})

    # Build required params list
    required_params = Enum.map(schema.required_params, &Atom.to_string/1)

    # Build the nested structure expected by tests
    params_schema = %{
      "type" => "object",
      "properties" => properties,
      "required" => required_params
    }

    # Build the complete JSON schema with action name and params
    json_schema = %{
      "action" => Atom.to_string(action),
      "params" => params_schema
    }

    # For non-wait actions, also add wait at top level and in required array
    if Schema.wait_required?(action) do
      json_schema
      |> Map.put("wait", format_wait_type())
      |> Map.put("required", ["wait"])
    else
      # For :wait action, don't add wait field at all
      json_schema
    end
  end

  # Build XOR schema (mutually exclusive parameter groups)
  # e.g., execute_shell has [[:command], [:check_id]] - must use one or the other
  defp build_xor_schema(:call_mcp, schema, _xor_params) do
    # call_mcp needs special 3-mode handling: CONNECT, CALL, TERMINATE
    build_call_mcp_schema(schema)
  end

  defp build_xor_schema(action, schema, xor_params) do
    param_descriptions = Map.get(schema, :param_descriptions, %{})
    all_params = schema.required_params ++ schema.optional_params

    # Build oneOf options - one for each XOR group
    one_of_options =
      Enum.map(xor_params, fn xor_group ->
        # This XOR group's params become required
        xor_required = xor_group

        # Other params (not in any XOR group) remain optional
        all_xor_params = List.flatten(xor_params)
        shared_params = all_params -- all_xor_params

        # Build properties for this variant
        variant_params = xor_required ++ shared_params

        properties =
          variant_params
          |> Enum.map(fn param ->
            type = Map.get(schema.param_types, param, :string)
            formatted = format_param_type(type)
            wrapped = if is_binary(formatted), do: %{"type" => formatted}, else: formatted

            # Add description if available
            final_type =
              case Map.get(param_descriptions, param) do
                nil -> wrapped
                desc -> Map.put(wrapped, "description", desc)
              end

            {Atom.to_string(param), final_type}
          end)
          |> Enum.into(%{})

        # Build required list (XOR params from this group only)
        required = Enum.map(xor_required, &Atom.to_string/1)

        # Get description for this mode
        mode_description = get_mode_description(action, xor_required)

        %{
          "type" => "object",
          "description" => mode_description,
          "properties" => properties,
          "required" => required
        }
      end)

    # Build the params schema with oneOf
    params_schema = %{
      "oneOf" => one_of_options
    }

    # Build the complete JSON schema
    json_schema = %{
      "action" => Atom.to_string(action),
      "params" => params_schema
    }

    # Add wait at top level if required
    if Schema.wait_required?(action) do
      json_schema
      |> Map.put("wait", format_wait_type())
      |> Map.put("required", ["wait"])
    else
      json_schema
    end
  end

  # Build special 3-mode schema for call_mcp: CONNECT, CALL, TERMINATE
  # Each mode shows ONLY the parameters relevant to that mode
  defp build_call_mcp_schema(schema) do
    param_descriptions = Map.get(schema, :param_descriptions, %{})

    # Helper to build a property with type and description
    build_prop = fn param ->
      type = Map.get(schema.param_types, param, :string)
      formatted = format_param_type(type)
      wrapped = if is_binary(formatted), do: %{"type" => formatted}, else: formatted

      case Map.get(param_descriptions, param) do
        nil -> wrapped
        desc -> Map.put(wrapped, "description", desc)
      end
    end

    # Mode 1: CONNECT - establish connection to MCP server
    connect_mode = %{
      "type" => "object",
      "description" => "CONNECT to a new MCP server (returns connection_id and available tools)",
      "properties" => %{
        "transport" => build_prop.(:transport),
        "command" => build_prop.(:command),
        "url" => build_prop.(:url),
        "cwd" => build_prop.(:cwd),
        "timeout" => build_prop.(:timeout)
      },
      "required" => ["transport"]
    }

    # Mode 2: CALL - invoke a tool on connected server
    call_mode = %{
      "type" => "object",
      "description" => "CALL a tool on an existing MCP connection",
      "properties" => %{
        "connection_id" => build_prop.(:connection_id),
        "tool" => build_prop.(:tool),
        "arguments" => build_prop.(:arguments),
        "timeout" => build_prop.(:timeout)
      },
      "required" => ["connection_id", "tool"]
    }

    # Mode 3: TERMINATE - close connection
    terminate_mode = %{
      "type" => "object",
      "description" => "TERMINATE an existing MCP connection (free resources)",
      "properties" => %{
        "connection_id" => build_prop.(:connection_id),
        "terminate" => build_prop.(:terminate)
      },
      "required" => ["connection_id", "terminate"]
    }

    params_schema = %{
      "oneOf" => [connect_mode, call_mode, terminate_mode]
    }

    json_schema = %{
      "action" => "call_mcp",
      "params" => params_schema
    }

    # Add wait at top level
    json_schema
    |> Map.put("wait", format_wait_type())
    |> Map.put("required", ["wait"])
  end

  # Get human-readable description for a parameter mode
  defp get_mode_description(:execute_shell, [:command]), do: "Start a new shell command"

  defp get_mode_description(:execute_shell, [:check_id]),
    do: "Check status or terminate a running command"

  # Note: :call_mcp has custom 3-mode schema via build_call_mcp_schema/1, not generic XOR
  defp get_mode_description(_action, _params), do: "Operation mode"

  @doc """
  Formats a parameter type to JSON schema type string.
  Converts Elixir types to JSON schema compatible types.
  """
  @spec format_param_type(term()) :: String.t() | map()
  def format_param_type(:string), do: "string"
  def format_param_type(:integer), do: "integer"
  def format_param_type(:atom), do: "string"
  def format_param_type(:boolean), do: "boolean"
  def format_param_type(:float), do: "number"
  def format_param_type(:number), do: "number"
  def format_param_type(:any), do: "any"

  # Action spec for batch_sync - enum constraint prevents LLMs using non-batchable actions
  def format_param_type(:batchable_action_spec) do
    allowed = Quoracle.Actions.Schema.ActionList.batchable_actions()

    %{
      "type" => "object",
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => Enum.map(allowed, &Atom.to_string/1)
        },
        "params" => %{"type" => "object", "description" => "Action parameters"}
      },
      "required" => ["action", "params"]
    }
  end

  # Action spec for batch_async - all actions except wait/batch_sync/batch_async
  def format_param_type(:async_action_spec) do
    excluded = Quoracle.Actions.Schema.ActionList.async_excluded_actions()
    allowed = Quoracle.Actions.Schema.ActionList.actions() -- excluded

    %{
      "type" => "object",
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => Enum.map(allowed, &Atom.to_string/1)
        },
        "params" => %{"type" => "object", "description" => "Action parameters"}
      },
      "required" => ["action", "params"]
    }
  end

  # Generic map (must come before nested map pattern)
  def format_param_type(:map), do: "object"

  # Nested map with explicit properties (all fields required)
  def format_param_type({:map, properties}) when is_map(properties) do
    json_properties =
      properties
      |> Enum.map(fn {key, type} ->
        formatted = format_param_type(type)

        # Wrap simple string types (e.g., "string", "integer") in {"type": "string"} for JSON schema consistency.
        # Complex types (e.g., {:enum, [...]}) already return maps and don't need wrapping.
        wrapped = if is_binary(formatted), do: %{"type" => formatted}, else: formatted
        {Atom.to_string(key), wrapped}
      end)
      |> Enum.into(%{})

    required_fields =
      properties
      |> Map.keys()
      |> Enum.map(&Atom.to_string/1)
      |> Enum.sort()

    %{
      "type" => "object",
      "properties" => json_properties,
      "required" => required_fields
    }
  end

  # Nested map with all fields optional
  def format_param_type({:map, properties, :all_optional}) when is_map(properties) do
    json_properties =
      properties
      |> Enum.map(fn {key, type} ->
        formatted = format_param_type(type)
        wrapped = if is_binary(formatted), do: %{"type" => formatted}, else: formatted
        {Atom.to_string(key), wrapped}
      end)
      |> Enum.into(%{})

    %{
      "type" => "object",
      "properties" => json_properties,
      "required" => []
    }
  end

  # Enum types
  def format_param_type({:enum, values}) when is_list(values) do
    string_values = Enum.map(values, &Atom.to_string/1)

    %{
      "type" => "string",
      "enum" => string_values
    }
  end

  # List types (recursive)
  def format_param_type({:list, item_type}) do
    formatted_item = format_param_type(item_type)

    items_schema =
      if is_binary(formatted_item) do
        %{"type" => formatted_item}
      else
        formatted_item
      end

    %{
      "type" => "array",
      "items" => items_schema
    }
  end

  def format_param_type({:union, types}) do
    # For simplicity, return a map indicating it can be multiple types
    %{
      "oneOf" => Enum.map(types, fn t -> %{"type" => format_param_type(t)} end)
    }
  end

  @doc """
  Formats the wait parameter type for JSON schema.
  Returns a map describing the wait parameter's type constraints.
  """
  @spec format_wait_type() :: map()
  def format_wait_type do
    %{
      "type" => ["boolean", "integer"],
      "minimum" => 0,
      "description" =>
        "Controls flow continuation: false/0 = continue immediately (more work to do), true = block until message (nothing else to do), integer > 0 = timeout check-in"
    }
  end

  @doc """
  Documents a single action with its JSON schema.
  Returns a formatted string suitable for LLM prompt inclusion.
  Includes action description with WHEN and HOW guidance.

  ## Options
    * `:profile_names` - List of profile names for spawn_child profile enum
  """
  @spec document_action_with_schema(atom(), keyword()) :: String.t()
  def document_action_with_schema(action, opts \\ []) do
    case action_to_json_schema(action, opts) do
      nil ->
        "#{action}: (schema unavailable)"

      json_schema ->
        action_name = json_schema["action"] || Atom.to_string(action)
        action_desc = Schema.get_action_description(action)
        params_schema = json_schema["params"]

        # Format as JSON to include "properties", "required", "type" keywords
        schema_json = Jason.encode!(params_schema, pretty: true)

        """
        #{action_name}: #{action_desc}
          JSON Schema:
          #{schema_json}
        """
        |> String.trim_trailing()
    end
  end
end
