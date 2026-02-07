defmodule Quoracle.Providers.RetryHelperTest do
  @moduledoc """
  Tests for RetryHelper v3.0 - 429/5xx retry with Retry-After support.
  WorkGroupID: fix-20251209-035351
  Packet 1: Foundation

  ARC Verification Criteria:
  - R1: Match ReqLLM.Error.API.Request with `status` field (not status_code)
  - R2: Use Retry-After header value when present
  - R3: Fall back to exponential backoff without Retry-After
  - R4: Retry 5xx errors with backoff
  - R5: Infinite retries for 429/5xx (no max_retries limit)
  - R6: Injectable delay function for testing
  - R7: Don't retry 401/403 authentication errors
  """

  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias Quoracle.Providers.RetryHelper

  # Use the actual ReqLLM error module for pattern matching
  # This ensures we test against the real struct format
  @error_module ReqLLM.Error.API.Request

  describe "R1: ReqLLM Error Pattern Match" do
    test "matches ReqLLM.Error.API.Request with status field" do
      # Track retry attempts
      attempts = :counters.new(1, [:atomics])
      delay_calls = :counters.new(1, [:atomics])

      # Create error with `status` field (ReqLLM style, NOT status_code)
      error = %@error_module{
        status: 429,
        reason: "Rate limited",
        response_body: %{}
      }

      # Function that fails with 429 twice, then succeeds
      func = fn ->
        attempt = :counters.get(attempts, 1)
        :counters.add(attempts, 1, 1)

        if attempt < 2 do
          {:error, error}
        else
          {:ok, "success"}
        end
      end

      result =
        RetryHelper.with_retry(func,
          initial_delay: 100,
          error_module: @error_module,
          delay_fn: fn _ms -> :counters.add(delay_calls, 1, 1) end
        )

      # Should have retried and succeeded
      assert result == {:ok, "success"}
      # Should have called delay at least once (for the retry)
      assert :counters.get(delay_calls, 1) >= 1
    end

    test "does not match when using old status_code field" do
      # This test verifies the CURRENT behavior is wrong
      # After fix, this struct format won't trigger retry
      attempts = :counters.new(1, [:atomics])

      # OLD format with status_code (OpenaiEx style) - should NOT work with ReqLLM
      old_error = %{
        __struct__: @error_module,
        status_code: 429,
        reason: "Rate limited"
      }

      func = fn ->
        attempt = :counters.get(attempts, 1)
        :counters.add(attempts, 1, 1)

        if attempt < 2 do
          {:error, old_error}
        else
          {:ok, "success"}
        end
      end

      # With correct implementation, this should NOT retry (wrong field)
      # Currently it might retry (using status_code) - this tests the fix is needed
      result =
        RetryHelper.with_retry(func,
          initial_delay: 10,
          error_module: @error_module,
          delay_fn: fn _ms -> :ok end
        )

      # After fix: should return error (no retry for wrong field format)
      # Test expects correct behavior - will fail until fix applied
      assert {:error, _} = result
    end
  end

  describe "R2: Retry-After Header Respected" do
    test "uses Retry-After header value when present in response_body" do
      delay_values = Agent.start_link(fn -> [] end) |> elem(1)

      error = %@error_module{
        status: 429,
        reason: "Rate limited",
        response_body: %{"retry_after" => 5}
      }

      attempts = :counters.new(1, [:atomics])

      func = fn ->
        attempt = :counters.get(attempts, 1)
        :counters.add(attempts, 1, 1)

        if attempt < 2 do
          {:error, error}
        else
          {:ok, "success"}
        end
      end

      _result =
        RetryHelper.with_retry(func,
          initial_delay: 1000,
          error_module: @error_module,
          delay_fn: fn ms ->
            Agent.update(delay_values, fn list -> [ms | list] end)
          end
        )

      delays = Agent.get(delay_values, & &1)
      Agent.stop(delay_values)

      # Should use Retry-After value (5 seconds = 5000ms), not initial_delay
      assert delays != []
      [first_delay | _] = Enum.reverse(delays)
      assert first_delay == 5000, "Expected Retry-After of 5000ms, got #{first_delay}ms"
    end

    test "uses Retry-After header with capital case" do
      delay_values = Agent.start_link(fn -> [] end) |> elem(1)

      error = %@error_module{
        status: 429,
        reason: "Rate limited",
        response_body: %{"Retry-After" => 10}
      }

      attempts = :counters.new(1, [:atomics])

      func = fn ->
        attempt = :counters.get(attempts, 1)
        :counters.add(attempts, 1, 1)

        if attempt < 2 do
          {:error, error}
        else
          {:ok, "success"}
        end
      end

      _result =
        RetryHelper.with_retry(func,
          initial_delay: 1000,
          error_module: @error_module,
          delay_fn: fn ms ->
            Agent.update(delay_values, fn list -> [ms | list] end)
          end
        )

      delays = Agent.get(delay_values, & &1)
      Agent.stop(delay_values)

      assert delays != []
      [first_delay | _] = Enum.reverse(delays)
      assert first_delay == 10_000, "Expected Retry-After of 10000ms, got #{first_delay}ms"
    end
  end

  describe "R3: Fallback to Exponential Backoff" do
    test "falls back to exponential backoff without Retry-After" do
      delay_values = Agent.start_link(fn -> [] end) |> elem(1)

      # Error WITHOUT Retry-After header
      error = %@error_module{
        status: 429,
        reason: "Rate limited",
        response_body: %{}
      }

      attempts = :counters.new(1, [:atomics])

      func = fn ->
        attempt = :counters.get(attempts, 1)
        :counters.add(attempts, 1, 1)

        if attempt < 3 do
          {:error, error}
        else
          {:ok, "success"}
        end
      end

      _result =
        RetryHelper.with_retry(func,
          initial_delay: 100,
          error_module: @error_module,
          delay_fn: fn ms ->
            Agent.update(delay_values, fn list -> [ms | list] end)
          end
        )

      delays = Agent.get(delay_values, & &1) |> Enum.reverse()
      Agent.stop(delay_values)

      # Should have exponential backoff: 100, 200, ...
      assert length(delays) >= 2
      [first, second | _] = delays
      assert first == 100
      assert second == 200, "Expected exponential backoff 200ms, got #{second}ms"
    end
  end

  describe "R4: 5xx Error Retry" do
    test "retries 5xx errors with exponential backoff" do
      attempts = :counters.new(1, [:atomics])
      delay_calls = :counters.new(1, [:atomics])

      error = %@error_module{
        status: 503,
        reason: "Service Unavailable",
        response_body: %{}
      }

      func = fn ->
        attempt = :counters.get(attempts, 1)
        :counters.add(attempts, 1, 1)

        if attempt < 2 do
          {:error, error}
        else
          {:ok, "success"}
        end
      end

      result =
        RetryHelper.with_retry(func,
          initial_delay: 100,
          error_module: @error_module,
          delay_fn: fn _ms -> :counters.add(delay_calls, 1, 1) end
        )

      assert result == {:ok, "success"}
      assert :counters.get(delay_calls, 1) >= 1
    end

    test "retries all 5xx status codes" do
      for status <- [500, 502, 503, 504] do
        attempts = :counters.new(1, [:atomics])

        error = %@error_module{
          status: status,
          reason: "Server Error",
          response_body: %{}
        }

        func = fn ->
          attempt = :counters.get(attempts, 1)
          :counters.add(attempts, 1, 1)

          if attempt < 2 do
            {:error, error}
          else
            {:ok, "success for #{status}"}
          end
        end

        result =
          RetryHelper.with_retry(func,
            initial_delay: 10,
            error_module: @error_module,
            delay_fn: fn _ms -> :ok end
          )

        assert result == {:ok, "success for #{status}"},
               "Should retry #{status} error"
      end
    end
  end

  describe "R5: Infinite Retries for 429/5xx" do
    test "continues retrying 429/5xx without max limit" do
      # This test verifies that there's NO max_retries limit
      # We'll retry many times to prove it keeps going
      attempts = :counters.new(1, [:atomics])
      target_attempts = 10

      error = %@error_module{
        status: 429,
        reason: "Rate limited",
        response_body: %{}
      }

      func = fn ->
        attempt = :counters.get(attempts, 1)
        :counters.add(attempts, 1, 1)

        if attempt < target_attempts do
          {:error, error}
        else
          {:ok, "finally succeeded after #{attempt} attempts"}
        end
      end

      result =
        RetryHelper.with_retry(func,
          initial_delay: 1,
          error_module: @error_module,
          delay_fn: fn _ms -> :ok end
        )

      # Should have succeeded after many retries (no max_retries limit)
      assert {:ok, msg} = result
      assert msg =~ "#{target_attempts} attempts"

      # Verify we actually made that many attempts
      # Counter is read-then-increment, so final value is target + 1
      assert :counters.get(attempts, 1) == target_attempts + 1
    end

    test "does not return rate_limit_exceeded for 429" do
      # Current implementation returns :rate_limit_exceeded after max_retries
      # After fix, it should keep retrying (never return :rate_limit_exceeded for 429)
      attempts = :counters.new(1, [:atomics])

      error = %@error_module{
        status: 429,
        reason: "Rate limited",
        response_body: %{}
      }

      # Function that eventually succeeds after 5 attempts
      func = fn ->
        attempt = :counters.get(attempts, 1)
        :counters.add(attempts, 1, 1)

        if attempt < 5 do
          {:error, error}
        else
          {:ok, "success"}
        end
      end

      result =
        RetryHelper.with_retry(func,
          # Old default was max_retries: 3, which would fail here
          initial_delay: 1,
          error_module: @error_module,
          delay_fn: fn _ms -> :ok end
        )

      # Should NOT return :rate_limit_exceeded - should succeed
      refute result == {:error, :rate_limit_exceeded},
             "Should not give up after max_retries - expected infinite retries"

      assert result == {:ok, "success"}
    end
  end

  describe "R6: Injectable Delay Function" do
    test "uses injectable delay function for testing" do
      delay_values = Agent.start_link(fn -> [] end) |> elem(1)

      error = %@error_module{
        status: 429,
        reason: "Rate limited",
        response_body: %{}
      }

      attempts = :counters.new(1, [:atomics])

      func = fn ->
        attempt = :counters.get(attempts, 1)
        :counters.add(attempts, 1, 1)

        if attempt < 2 do
          {:error, error}
        else
          {:ok, "success"}
        end
      end

      custom_delay_fn = fn ms ->
        Agent.update(delay_values, fn list -> [{:custom_delay, ms} | list] end)
      end

      _result =
        RetryHelper.with_retry(func,
          initial_delay: 100,
          error_module: @error_module,
          delay_fn: custom_delay_fn
        )

      delays = Agent.get(delay_values, & &1)
      Agent.stop(delay_values)

      # Verify our custom delay function was called
      assert delays != []
      assert Enum.all?(delays, fn {tag, _ms} -> tag == :custom_delay end)
    end
  end

  describe "R7: Non-Retryable Errors Pass Through" do
    test "does not retry authentication errors (401)" do
      attempts = :counters.new(1, [:atomics])

      error = %@error_module{
        status: 401,
        reason: "Unauthorized",
        response_body: %{}
      }

      func = fn ->
        :counters.add(attempts, 1, 1)
        {:error, error}
      end

      # Capture expected Logger.error output
      result =
        capture_log(fn ->
          send(
            self(),
            {:result,
             RetryHelper.with_retry(func,
               initial_delay: 10,
               error_module: @error_module,
               delay_fn: fn _ms -> :ok end
             )}
          )
        end)

      assert result =~ "Authentication failed (401)"
      assert_received {:result, retry_result}

      # Should return error immediately without retry
      assert {:error, _} = retry_result
      # Should have only made 1 attempt (no retries)
      assert :counters.get(attempts, 1) == 1
    end

    test "does not retry forbidden errors (403)" do
      attempts = :counters.new(1, [:atomics])

      error = %@error_module{
        status: 403,
        reason: "Forbidden",
        response_body: %{}
      }

      func = fn ->
        :counters.add(attempts, 1, 1)
        {:error, error}
      end

      # Capture expected Logger.error output
      result =
        capture_log(fn ->
          send(
            self(),
            {:result,
             RetryHelper.with_retry(func,
               initial_delay: 10,
               error_module: @error_module,
               delay_fn: fn _ms -> :ok end
             )}
          )
        end)

      assert result =~ "Access forbidden (403)"
      assert_received {:result, retry_result}

      # Should return error immediately without retry
      assert {:error, _} = retry_result
      # Should have only made 1 attempt (no retries)
      assert :counters.get(attempts, 1) == 1
    end
  end
end
