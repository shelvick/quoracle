defmodule Quoracle.Groves.HardRuleEnforcer do
  @moduledoc """
  Enforces grove hard rules for shell commands and filesystem confinement.
  """

  require Logger

  alias Quoracle.Groves.SchemaValidator

  @type shell_hard_rule_violation :: %{
          type: String.t(),
          pattern: String.t(),
          command: String.t(),
          message: String.t()
        }

  @type action_hard_rule_violation :: %{
          type: String.t(),
          actions: [String.t()],
          action: String.t(),
          message: String.t()
        }

  @type hard_rule_violation :: shell_hard_rule_violation() | action_hard_rule_violation()

  @type shell_confinement_violation :: %{
          working_dir: String.t(),
          skill: String.t() | nil,
          allowed_paths: [String.t()],
          message: String.t()
        }

  @type file_confinement_violation :: %{
          path: String.t(),
          skill: String.t() | nil,
          access_type: :read | :write,
          allowed_paths: [String.t()],
          message: String.t()
        }

  @doc """
  Checks a shell command against typed `shell_pattern_block` hard rules.
  """
  @spec check_shell_command(String.t(), [map()] | nil, String.t() | nil) ::
          :ok | {:error, {:hard_rule_violation, hard_rule_violation()}}
  def check_shell_command(_command, hard_rules, _skill_name) when hard_rules in [nil, []], do: :ok

  def check_shell_command(command, hard_rules, skill_name)
      when is_binary(command) and is_list(hard_rules) do
    hard_rules
    |> Enum.reduce_while(:ok, fn rule, _acc ->
      case check_shell_rule(command, rule, skill_name) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  def check_shell_command(_command, _hard_rules, _skill_name), do: :ok

  @doc """
  Checks an action against typed `action_block` hard rules.
  """
  @spec check_action(atom() | String.t(), [map()] | nil, String.t() | nil) ::
          :ok | {:error, {:hard_rule_violation, action_hard_rule_violation()}}
  def check_action(_action, hard_rules, _skill_name) when hard_rules in [nil, []], do: :ok

  def check_action(action, hard_rules, skill_name)
      when (is_atom(action) or is_binary(action)) and is_list(hard_rules) do
    action_name = if is_atom(action), do: Atom.to_string(action), else: action

    hard_rules
    |> Enum.reduce_while(:ok, fn rule, _acc ->
      case check_action_rule(action_name, rule, skill_name) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  def check_action(_action, _hard_rules, _skill_name), do: :ok

  @doc """
  Validates that shell working directory is inside the confinement paths for a skill.
  """
  @spec check_shell_working_dir(String.t(), map() | nil, String.t() | nil) ::
          :ok | {:error, {:confinement_violation, shell_confinement_violation()}}
  def check_shell_working_dir(_working_dir, confinement, _skill_name)
      when confinement in [nil, %{}],
      do: :ok

  def check_shell_working_dir(working_dir, confinement, skill_name)
      when is_binary(working_dir) and is_map(confinement) do
    case confinement_entry(confinement, skill_name) do
      {:ok, entry} ->
        allowed_paths = confinement_paths(entry)

        if path_allowed?(working_dir, allowed_paths) do
          :ok
        else
          {:error,
           {:confinement_violation,
            %{
              working_dir: working_dir,
              skill: skill_name,
              allowed_paths: allowed_paths,
              message:
                "Working directory is outside allowed confinement paths for skill #{skill_name}"
            }}}
        end

      :allow_unlisted ->
        :ok
    end
  end

  def check_shell_working_dir(_working_dir, _confinement, _skill_name), do: :ok

  @doc """
  Validates file access against skill confinement paths.
  """
  @spec check_file_access(String.t(), :read | :write, map() | nil, String.t() | nil) ::
          :ok | {:error, {:confinement_violation, file_confinement_violation()}}
  def check_file_access(_path, _access_type, confinement, _skill_name)
      when confinement in [nil, %{}],
      do: :ok

  def check_file_access(path, access_type, confinement, skill_name)
      when is_binary(path) and access_type in [:read, :write] and is_map(confinement) do
    case confinement_entry(confinement, skill_name) do
      {:ok, entry} ->
        allowed_paths = allowed_paths_for_access(entry, access_type)

        if path_allowed?(path, allowed_paths) do
          :ok
        else
          {:error,
           {:confinement_violation,
            %{
              path: path,
              skill: skill_name,
              access_type: access_type,
              allowed_paths: allowed_paths,
              message:
                "File #{access_type} outside allowed confinement paths for skill #{skill_name}"
            }}}
        end

      :allow_unlisted ->
        :ok
    end
  end

  def check_file_access(_path, _access_type, _confinement, _skill_name), do: :ok

  @spec check_shell_rule(String.t(), map(), String.t() | nil) ::
          :ok | {:error, {:hard_rule_violation, shell_hard_rule_violation()}}
  defp check_shell_rule(
         command,
         %{"type" => "shell_pattern_block", "pattern" => pattern} = rule,
         skill_name
       )
       when is_binary(pattern) do
    if rule_applies?(rule, skill_name) do
      case Regex.compile(pattern) do
        {:ok, regex} ->
          if Regex.match?(regex, command) do
            {:error,
             {:hard_rule_violation,
              %{
                type: "shell_pattern_block",
                pattern: pattern,
                command: command,
                message: rule_message(rule)
              }}}
          else
            :ok
          end

        {:error, reason} ->
          log_warning("Invalid hard rule regex '#{pattern}': #{inspect(reason)}")
          :ok
      end
    else
      :ok
    end
  end

  defp check_shell_rule(_command, _rule, _skill_name), do: :ok

  @spec check_action_rule(String.t(), map(), String.t() | nil) ::
          :ok | {:error, {:hard_rule_violation, action_hard_rule_violation()}}
  defp check_action_rule(
         action_name,
         %{"type" => "action_block", "actions" => actions} = rule,
         skill_name
       )
       when is_binary(action_name) and is_list(actions) do
    if rule_applies?(rule, skill_name) do
      valid_actions = Enum.filter(actions, &is_binary/1)

      if action_name in valid_actions do
        {:error,
         {:hard_rule_violation,
          %{
            type: "action_block",
            actions: valid_actions,
            action: action_name,
            message: rule_message(rule)
          }}}
      else
        :ok
      end
    else
      :ok
    end
  end

  defp check_action_rule(_action_name, _rule, _skill_name), do: :ok

  @spec rule_applies?(map(), String.t() | nil) :: boolean()
  defp rule_applies?(rule, skill_name) do
    case Map.get(rule, "scope") do
      "all" -> true
      scope when is_list(scope) -> skill_name in scope
      _ -> true
    end
  end

  @spec rule_message(map()) :: String.t()
  defp rule_message(rule) do
    case Map.get(rule, "message") do
      message when is_binary(message) and message != "" -> message
      _ -> "Action blocked by grove hard rule"
    end
  end

  @spec confinement_entry(map(), String.t() | nil) :: {:ok, map()} | :allow_unlisted
  defp confinement_entry(confinement, skill_name) do
    case Map.get(confinement, skill_name) do
      entry when is_map(entry) ->
        {:ok, entry}

      _ ->
        log_warning("No confinement entry for skill #{inspect(skill_name)}, allowing access")
        :allow_unlisted
    end
  end

  @spec confinement_paths(map()) :: [String.t()]
  defp confinement_paths(entry) do
    case Map.get(entry, "paths") do
      paths when is_list(paths) -> paths
      _ -> []
    end
  end

  @spec read_only_paths(map()) :: [String.t()]
  defp read_only_paths(entry) do
    case Map.get(entry, "read_only_paths") do
      paths when is_list(paths) -> paths
      _ -> []
    end
  end

  @spec allowed_paths_for_access(map(), :read | :write) :: [String.t()]
  defp allowed_paths_for_access(entry, :write), do: confinement_paths(entry)

  defp allowed_paths_for_access(entry, :read),
    do: confinement_paths(entry) ++ read_only_paths(entry)

  @spec path_allowed?(String.t(), [String.t()]) :: boolean()
  defp path_allowed?(path, patterns) when is_binary(path) and is_list(patterns) do
    expanded_path = Path.expand(path)

    Enum.any?(patterns, fn
      pattern when is_binary(pattern) ->
        pattern
        |> expand_home_pattern()
        |> then(&SchemaValidator.path_matches_pattern?(expanded_path, &1))

      _ ->
        false
    end)
  end

  @spec expand_home_pattern(String.t()) :: String.t()
  defp expand_home_pattern(pattern) when is_binary(pattern) do
    home = System.user_home!()

    case pattern do
      "~" ->
        home

      "~/" <> rest ->
        Path.join(home, rest)

      _ ->
        pattern
    end
  end

  @spec log_warning(String.t()) :: :ok
  defp log_warning(message) when is_binary(message) do
    Logger.bare_log(:warning, message)

    # In test env, global logger level is :error, so mirror the message at :error
    # to keep warning-behavior assertions observable via capture_log/1.
    if Logger.compare_levels(Logger.level(), :warning) == :gt do
      Logger.bare_log(:error, message)
    end

    :ok
  end
end
