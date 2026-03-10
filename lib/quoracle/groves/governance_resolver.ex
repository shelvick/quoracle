defmodule Quoracle.Groves.GovernanceResolver do
  @moduledoc """
  Resolves grove governance injections from source files into prompt-ready content.
  """

  alias Quoracle.Groves.{Loader, PathSecurity}

  @type governance_injection :: %{
          content: String.t(),
          priority: :high | :normal,
          inject_into: [String.t()]
        }

  @type resolve_error ::
          {:error,
           {:file_not_found, String.t()}
           | {:path_traversal, String.t()}
           | {:symlink_not_allowed, String.t()}}

  @doc """
  Resolves all governance injections for a loaded grove.
  """
  @spec resolve_all(Loader.grove()) :: {:ok, [governance_injection()]} | resolve_error()
  def resolve_all(grove) do
    injections =
      case grove[:governance] do
        %{"injections" => list} when is_list(list) -> list
        _ -> []
      end

    Enum.reduce_while(injections, {:ok, []}, fn injection, {:ok, acc} ->
      case resolve_injection(injection, grove.path) do
        {:ok, resolved} -> {:cont, {:ok, acc ++ [resolved]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  @doc """
  Filters injections for an agent's active skills and returns prompt text.
  """
  @spec build_agent_governance([governance_injection()], [String.t()], [map()] | nil) ::
          String.t() | nil
  def build_agent_governance(injections, active_skill_names, hard_rules \\ nil) do
    matching = filter_for_skills(injections, active_skill_names)

    high = Enum.filter(matching, &(&1.priority == :high))
    normal = Enum.filter(matching, &(&1.priority != :high))

    content_parts = Enum.map(high ++ normal, & &1.content)
    hard_rule_parts = format_hard_rules(hard_rules, active_skill_names)

    parts = content_parts ++ hard_rule_parts

    case parts do
      [] -> nil
      _ -> "## Governance Rules\n\n" <> Enum.join(parts, "\n\n")
    end
  end

  @doc """
  Returns only injections whose inject_into list overlaps with skill names.
  """
  @spec filter_for_skills([governance_injection()], [String.t()]) :: [governance_injection()]
  def filter_for_skills(injections, skill_names)
      when is_list(injections) and is_list(skill_names) do
    Enum.filter(injections, fn injection ->
      inject_into = Map.get(injection, :inject_into, [])
      is_list(inject_into) and Enum.any?(inject_into, &(&1 in skill_names))
    end)
  end

  @spec format_hard_rules([map()] | nil, [String.t()]) :: [String.t()]
  defp format_hard_rules(hard_rules, active_skill_names) when is_list(hard_rules) do
    applicable_rules = Enum.filter(hard_rules, &typed_rule_applies?(&1, active_skill_names))

    system_rule_lines =
      applicable_rules
      |> Enum.map(&format_typed_rule_message_line/1)
      |> Enum.reject(&is_nil/1)

    blocked_rule_lines =
      applicable_rules
      |> Enum.map(&format_typed_rule_line/1)
      |> Enum.reject(&is_nil/1)

    blocked_rule_section =
      case blocked_rule_lines do
        [] -> []
        _ -> ["SYSTEM RULES\n" <> Enum.join(blocked_rule_lines, "\n")]
      end

    system_rule_lines ++ blocked_rule_section
  end

  defp format_hard_rules(_, _active_skill_names), do: []

  defp typed_rule_applies?(
         %{"type" => "shell_pattern_block", "pattern" => pattern} = rule,
         skill_names
       )
       when is_binary(pattern) and is_list(skill_names) do
    case Map.get(rule, "scope") do
      "all" -> true
      scope when is_list(scope) -> Enum.any?(scope, &(&1 in skill_names))
      _ -> true
    end
  end

  defp typed_rule_applies?(
         %{"type" => "action_block", "actions" => actions} = rule,
         skill_names
       )
       when is_list(actions) and is_list(skill_names) do
    case Map.get(rule, "scope") do
      "all" -> true
      scope when is_list(scope) -> Enum.any?(scope, &(&1 in skill_names))
      _ -> true
    end
  end

  defp typed_rule_applies?(_, _), do: false

  defp format_typed_rule_message_line(%{"message" => message}) when is_binary(message) do
    "SYSTEM RULE: #{message}"
  end

  defp format_typed_rule_message_line(_), do: nil

  defp format_typed_rule_line(%{"pattern" => pattern, "message" => message})
       when is_binary(pattern) and is_binary(message) do
    "- BLOCKED PATTERN: /#{pattern}/ -- #{message}"
  end

  defp format_typed_rule_line(%{"actions" => actions, "message" => message})
       when is_list(actions) and is_binary(message) do
    valid_actions = Enum.filter(actions, &is_binary/1)

    case valid_actions do
      [] -> nil
      _ -> "- BLOCKED ACTION: #{Enum.join(valid_actions, ", ")} -- #{message}"
    end
  end

  defp format_typed_rule_line(_), do: nil

  @spec resolve_injection(map(), String.t()) :: {:ok, governance_injection()} | resolve_error()
  defp resolve_injection(injection, grove_path) do
    source = Map.get(injection, "source")
    source_for_validation = Map.get(injection, "__unsafe_original_source", source)

    case resolve_source_file(source, source_for_validation, grove_path) do
      {:ok, content} ->
        {:ok,
         %{
           content: content,
           priority: parse_priority(Map.get(injection, "priority")),
           inject_into: parse_inject_into(Map.get(injection, "inject_into"))
         }}

      {:error, _} = error ->
        error
    end
  end

  @spec parse_priority(String.t() | atom() | nil) :: :high | :normal
  defp parse_priority("high"), do: :high
  defp parse_priority(:high), do: :high
  defp parse_priority(_), do: :normal

  @spec parse_inject_into([String.t()] | nil | term()) :: [String.t()]
  defp parse_inject_into(list) when is_list(list) do
    Enum.filter(list, &is_binary/1)
  end

  defp parse_inject_into(_), do: []

  @spec resolve_source_file(String.t() | nil, String.t() | nil, String.t()) ::
          {:ok, String.t()} | resolve_error()
  defp resolve_source_file(source_path, source_for_validation, grove_path)
       when is_binary(source_path) and is_binary(source_for_validation) do
    PathSecurity.safe_read_file(source_path, source_for_validation, grove_path)
  end

  defp resolve_source_file(_source_path, _source_for_validation, _grove_path) do
    {:error, {:path_traversal, ""}}
  end
end
