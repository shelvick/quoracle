defmodule Quoracle.Actions.Router.MockExecution do
  @moduledoc """
  Mock execution logic for testing actions that don't have real implementations yet.
  This module is extracted from Router to keep it under 500 lines.
  """

  @doc """
  Execute a mock action for testing purposes.
  Returns realistic mock responses for each action type.
  """
  @spec execute_mock(atom(), map(), String.t()) :: {:ok, any()} | {:error, any()}
  def execute_mock(action, params, _action_id) do
    # First validate required parameters
    validation_result = validate_required_params(action, params)

    case validation_result do
      :ok ->
        execute_mock_action(action, params)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Validate that required parameters are present for an action.
  Returns :ok if all required parameters are present, {:error, reason} otherwise.
  """
  @spec validate_required_params(atom(), map()) :: :ok | {:error, atom()}
  def validate_required_params(:orient, params) do
    required = [:current_situation, :goal_clarity, :available_resources, :key_challenges]

    if Enum.all?(required, &Map.has_key?(params, &1)) do
      :ok
    else
      {:error, :missing_required_param}
    end
  end

  def validate_required_params(:send_message, params) do
    # Schema defines :to and :content as required
    if Map.has_key?(params, :to) and Map.has_key?(params, :content) do
      :ok
    else
      {:error, :missing_required_param}
    end
  end

  def validate_required_params(:spawn_child, params) do
    # Schema defines :task as required
    if Map.has_key?(params, :task) do
      :ok
    else
      {:error, :missing_required_param}
    end
  end

  def validate_required_params(:execute_shell, params) do
    # XOR validation for command/check_id
    has_command = Map.has_key?(params, :command)
    has_check_id = Map.has_key?(params, :check_id)

    case {has_command, has_check_id} do
      {true, true} ->
        {:error, :xor_violation}

      {true, false} ->
        :ok

      {false, true} ->
        :ok

      {false, false} ->
        {:error, :missing_required_param}
    end
  end

  def validate_required_params(:call_api, params) do
    if Map.has_key?(params, :endpoint) and Map.has_key?(params, :method) do
      :ok
    else
      {:error, :missing_required_param}
    end
  end

  def validate_required_params(_, _params) do
    # For other actions, assume params are ok
    :ok
  end

  # Private functions for executing mock actions
  defp execute_mock_action(:wait, params) do
    duration = Map.get(params, :duration, 1000)

    if duration < 0 do
      {:error, :invalid_duration}
    else
      # For testing, we don't actually wait
      {:ok, %{waited: duration}}
    end
  end

  defp execute_mock_action(:orient, _params) do
    {:ok,
     %{
       assessment: "Current situation analyzed",
       reflection: "Strategic perspective gained",
       clarity_level: 0.85
     }}
  end

  defp execute_mock_action(:spawn_child, _params) do
    {:ok, %{child_pid: self()}}
  end

  defp execute_mock_action(:send_message, _params) do
    {:ok, %{sent: true}}
  end

  defp execute_mock_action(:execute_shell, params) do
    # Check for XOR params
    case {Map.get(params, :command), Map.get(params, :check_id)} do
      {command, check_id} when not is_nil(command) and not is_nil(check_id) ->
        {:error, :xor_violation}

      {"echo test", nil} ->
        {:ok, %{output: "test\n", exit_code: 0}}

      {"sleep 0.1 && echo done", nil} ->
        # Simulate the sleep delay for realistic testing
        Process.sleep(100)
        {:ok, "done\n"}

      {command, nil} when not is_nil(command) ->
        {:ok, %{output: "Mock output", exit_code: 0}}

      {nil, check_id} when not is_nil(check_id) ->
        {:ok, %{check_result: "success"}}

      {nil, nil} ->
        {:error, :missing_required_param}
    end
  end

  defp execute_mock_action(:fetch_web, params) do
    url = Map.get(params, :url, "")

    if String.contains?(url, "invalid") do
      {:error, :connection_failed}
    else
      {:ok, %{content: "<html>Test page</html>"}}
    end
  end

  defp execute_mock_action(:call_api, _params) do
    {:ok, %{status: 200, body: "{\"result\": \"success\"}"}}
  end

  defp execute_mock_action(:answer_engine, _params) do
    {:ok, %{answer: "42"}}
  end

  defp execute_mock_action(:call_mcp, _params) do
    {:ok, %{result: "MCP response"}}
  end

  defp execute_mock_action(_, _params) do
    {:error, :unknown_action}
  end
end
