defmodule Quoracle.Actions.Wait do
  @moduledoc """
  Wait action that pauses execution for a specified duration in seconds.
  Agents may wait for extended periods as part of their normal operation.
  Broadcasts events through PubSub for UI updates.

  Duration is specified in seconds and converted internally to milliseconds.
  Always executes asynchronously, returning immediately with a timer reference.
  The caller receives a {:wait_expired, timer_ref} message when the timer expires.
  """

  require Logger

  @doc """
  Executes a wait for the specified value.

  Standard 3-arity signature with optional dependency injection.

  ## Parameters
    - params: Map with :wait (true/false/number in seconds)
    - agent_id: Agent identifier string
    - opts: Keyword list of options

  ## Options
    - `:agent_pid` - Process to send timer message to (default: self())
    - `:pubsub` - PubSub to use for broadcasting events (default: Quoracle.PubSub)
    - `:registry` - Registry (accepted for compatibility, not used)

  ## Returns
    - `{:ok, map()}` with timer_id, async flag, and wait info
    - `{:error, :invalid_wait_value}` for negative numbers or invalid types
  """
  @spec execute(map(), String.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def execute(params, agent_id, opts \\ []) when is_binary(agent_id) and is_list(opts) do
    pubsub = Keyword.fetch!(opts, :pubsub)
    caller = Keyword.get(opts, :agent_pid, self())

    # R2: Reject duration parameter (breaking change - no backward compatibility)
    if Map.has_key?(params, :duration) or Map.has_key?(params, "duration") do
      {:error, :invalid_wait_value}
    else
      # R10: Distinguish between missing parameter and explicit nil
      # Missing parameter -> default to 0
      # Explicit nil -> reject
      wait =
        cond do
          Map.has_key?(params, :wait) ->
            params[:wait]

          Map.has_key?(params, "wait") ->
            params["wait"]

          true ->
            # Missing parameter defaults to 0
            0
        end

      # Reject explicit nil
      if wait == nil do
        {:error, :invalid_wait_value}
      else
        # Broadcast wait started event if pubsub is provided
        Phoenix.PubSub.broadcast(pubsub, "wait:events", {
          :wait_started,
          %{agent_id: agent_id, wait: wait}
        })

        # Execute with appropriate async mode
        execute_async(wait, caller)
      end
    end
  end

  # Handle boolean false and zero - immediate continuation
  # R4, R5: async: false for immediate continuation
  defp execute_async(wait, _caller) when wait == false or wait == 0 do
    {:ok,
     %{
       action: "wait",
       async: false
     }}
  end

  # Handle boolean true - indefinite wait (no timer)
  defp execute_async(true, _caller) do
    {:ok,
     %{
       action: "wait",
       async: true
     }}
  end

  # Handle negative numbers - error
  defp execute_async(wait, _caller) when is_number(wait) and wait < 0 do
    {:error, :invalid_wait_value}
  end

  # Handle positive numbers - timed wait
  defp execute_async(wait, caller) when is_number(wait) and wait > 0 do
    # Convert seconds to milliseconds
    # LLMs pass wait in seconds, but Process.send_after expects milliseconds
    wait_ms = trunc(wait * 1000)

    # Create new timer
    # The timer_id serves as both the reference and the identifier
    timer_ref = make_ref()
    Process.send_after(caller, {:wait_expired, timer_ref}, wait_ms)

    # Return in format expected by Router
    # The async: true flag indicates this completed immediately but has ongoing work
    {:ok,
     %{
       action: "wait",
       async: true,
       timer_id: timer_ref
     }}
  end

  # Handle invalid types
  defp execute_async(_wait, _caller) do
    {:error, :invalid_wait_value}
  end

  @doc """
  Cancels a timer using the timer_id from the response.
  Returns :ok even if the timer doesn't exist (for backward compatibility).
  """
  @spec cancel_timer(reference()) :: :ok
  def cancel_timer(timer_ref) when is_reference(timer_ref) do
    Process.cancel_timer(timer_ref)
    :ok
  end
end
