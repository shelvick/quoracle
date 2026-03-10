defmodule Quoracle.Groves.Loader.Sanitizer do
  @moduledoc """
  Sanitization functions for grove manifest data.

  Extracted from Loader to keep the main module under 500 lines.
  Handles sanitization of governance injections, hard rules, confinement
  entries, schema definitions, and workspace paths from YAML frontmatter.
  """

  @doc """
  Sanitizes governance section from grove frontmatter.
  Processes injections (source path sanitization) and hard rules (type/pattern/message validation).
  """
  @spec sanitize_governance(map() | nil) :: map() | nil
  def sanitize_governance(nil), do: nil

  def sanitize_governance(governance) when is_map(governance) do
    injections = Map.get(governance, "injections")
    hard_rules = Map.get(governance, "hard_rules")

    sanitized_injections =
      if is_list(injections) do
        Enum.map(injections, &sanitize_injection/1)
      else
        injections
      end

    sanitized_hard_rules = sanitize_hard_rules(hard_rules)

    governance
    |> Map.put("injections", sanitized_injections)
    |> Map.put("hard_rules", sanitized_hard_rules)
  end

  def sanitize_governance(governance), do: governance

  @doc """
  Sanitizes confinement section from grove frontmatter.
  Normalizes skill keys to strings, expands paths, and filters non-binary entries.
  """
  @spec sanitize_confinement(map() | nil) :: map() | nil
  def sanitize_confinement(nil), do: nil

  def sanitize_confinement(confinement) when is_map(confinement) do
    confinement
    |> Enum.reduce(%{}, fn {skill, config}, acc ->
      case sanitize_confinement_entry(config) do
        nil -> acc
        entry -> Map.put(acc, to_string(skill), entry)
      end
    end)
  end

  def sanitize_confinement(_), do: nil

  @doc """
  Sanitizes schema definition file references by applying path sanitization.
  """
  @spec sanitize_schema_definitions([map()] | nil, (map(), String.t() -> String.t() | nil)) ::
          [map()] | nil
  def sanitize_schema_definitions(schemas, safe_file_ref_fn) when is_list(schemas) do
    Enum.map(schemas, &sanitize_schema_definition(&1, safe_file_ref_fn))
  end

  def sanitize_schema_definitions(_, _safe_file_ref_fn), do: nil

  @doc """
  Parses workspace path by expanding it, or returns nil for non-binary input.
  """
  @spec parse_workspace(String.t() | nil) :: String.t() | nil
  def parse_workspace(workspace) when is_binary(workspace), do: Path.expand(workspace)
  def parse_workspace(_), do: nil

  # --- Injection sanitization ---

  defp sanitize_injection(injection) when is_map(injection) do
    source = get_string(injection, "source")

    case source do
      nil ->
        injection

      path when is_binary(path) ->
        sanitized = get_safe_file_ref(%{"source" => path}, "source")

        injection
        |> maybe_set_sanitized_source(sanitized)
        |> maybe_track_original_source(path, sanitized)
    end
  end

  defp sanitize_injection(injection), do: injection

  defp maybe_set_sanitized_source(injection, sanitized) when is_binary(sanitized) do
    Map.put(injection, "source", sanitized)
  end

  defp maybe_set_sanitized_source(injection, _sanitized), do: injection

  defp maybe_track_original_source(injection, original, sanitized)
       when is_binary(sanitized) and sanitized != original do
    Map.put(injection, "__unsafe_original_source", original)
  end

  defp maybe_track_original_source(injection, _original, _sanitized), do: injection

  # --- Hard rules sanitization ---

  defp sanitize_hard_rules(nil), do: nil

  # Canonical format: list of typed rule maps (e.g. from GROVE.md hard_rules as YAML list)
  defp sanitize_hard_rules(rules) when is_list(rules) do
    rules
    |> Enum.reduce([], fn rule, acc ->
      case sanitize_hard_rule(rule) do
        nil -> acc
        sanitized -> [sanitized | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp sanitize_hard_rules(_), do: nil

  defp sanitize_hard_rule(
         %{"type" => "shell_pattern_block", "pattern" => pattern, "message" => message} = rule
       )
       when is_binary(pattern) and pattern != "" and is_binary(message) and message != "" do
    %{
      "type" => "shell_pattern_block",
      "pattern" => pattern,
      "message" => message,
      "scope" => sanitize_rule_scope(Map.get(rule, "scope"))
    }
  end

  defp sanitize_hard_rule(
         %{"type" => "action_block", "actions" => actions, "message" => message} = rule
       )
       when is_list(actions) and is_binary(message) and message != "" do
    case sanitize_actions(actions) do
      [] ->
        nil

      sanitized_actions ->
        %{
          "type" => "action_block",
          "actions" => sanitized_actions,
          "message" => message,
          "scope" => sanitize_rule_scope(Map.get(rule, "scope"))
        }
    end
  end

  defp sanitize_hard_rule(_), do: nil

  defp sanitize_actions(actions) do
    Enum.filter(actions, &(is_binary(&1) and &1 != ""))
  end

  defp sanitize_rule_scope("all"), do: "all"

  defp sanitize_rule_scope(scope) when is_list(scope) do
    values = Enum.filter(scope, &(is_binary(&1) and &1 != ""))
    if values == [], do: "all", else: values
  end

  defp sanitize_rule_scope(_), do: "all"

  # --- Confinement sanitization ---

  defp sanitize_confinement_entry(config) when is_map(config) do
    %{
      "paths" => sanitize_path_list(Map.get(config, "paths")),
      "read_only_paths" => sanitize_path_list(Map.get(config, "read_only_paths"))
    }
  end

  defp sanitize_confinement_entry(_), do: nil

  defp sanitize_path_list(paths) when is_list(paths) do
    paths
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&Path.expand/1)
  end

  defp sanitize_path_list(_), do: []

  # --- Schema sanitization ---

  defp sanitize_schema_definition(schema, safe_file_ref_fn) when is_map(schema) do
    case Map.get(schema, "definition") do
      definition when is_binary(definition) ->
        Map.put(
          schema,
          "definition",
          safe_file_ref_fn.(%{"definition" => definition}, "definition")
        )

      _ ->
        schema
    end
  end

  defp sanitize_schema_definition(schema, _safe_file_ref_fn), do: schema

  # --- Shared helpers (duplicated from Loader to maintain isolation) ---

  defp get_string(map, key) do
    case Map.get(map, key) do
      nil -> nil
      value when is_binary(value) -> value
      value -> to_string(value)
    end
  end

  # Sanitize file reference paths: strip `..` components and leading `/`
  # to prevent path traversal attacks from grove manifests.
  defp get_safe_file_ref(map, key) do
    case get_string(map, key) do
      nil ->
        nil

      path ->
        sanitized =
          path
          |> Path.split()
          |> Enum.reject(&(&1 == ".."))
          |> then(fn
            ["/" | rest] -> rest
            parts -> parts
          end)
          |> Path.join()

        if sanitized == "", do: nil, else: sanitized
    end
  end
end
