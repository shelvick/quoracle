defmodule Quoracle.Actions.WebPropertyTest do
  @moduledoc """
  Property-based tests for Web action parameter validation.
  These tests verify validation logic WITHOUT making real HTTP calls.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Quoracle.Actions.Web

  setup do
    pubsub = :"test_pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub})

    %{
      opts: [agent_pid: self(), pubsub: pubsub],
      agent_id: "agent-#{System.unique_integer([:positive])}"
    }
  end

  describe "URL validation properties" do
    property "rejects all non-HTTP(S) schemes", %{opts: opts, agent_id: agent_id} do
      check all(
              scheme <- member_of(["ftp", "file", "javascript", "data", "ssh", "telnet"]),
              rest <- string(:alphanumeric, min_length: 5),
              max_runs: 20
            ) do
        url = "#{scheme}://#{rest}"
        params = %{url: url}

        assert {:error, :invalid_url_format} = Web.execute(params, agent_id, opts)
      end
    end

    property "blocks RFC1918 addresses when security_check enabled", %{
      opts: opts,
      agent_id: agent_id
    } do
      check all(
              oct2 <- integer(0..255),
              oct3 <- integer(0..255),
              oct4 <- integer(0..255),
              max_runs: 20
            ) do
        # Test different RFC1918 ranges
        urls = [
          "http://10.#{oct2}.#{oct3}.#{oct4}",
          "http://192.168.#{oct3}.#{oct4}"
        ]

        # Add 172.16-31 range
        urls =
          if oct2 in 16..31 do
            ["http://172.#{oct2}.#{oct3}.#{oct4}" | urls]
          else
            urls
          end

        for url <- urls do
          params = %{url: url, security_check: true}
          assert {:error, :blocked_domain} = Web.execute(params, agent_id, opts)
        end
      end
    end
  end

  describe "timeout validation" do
    property "negative timeouts are rejected", %{opts: opts, agent_id: agent_id} do
      check all(timeout <- integer(-10000..-1), max_runs: 20) do
        params = %{
          url: "http://example.com",
          timeout: timeout
        }

        # Should reject negative timeouts (validation before network call)
        assert {:error, :invalid_timeout} = Web.execute(params, agent_id, opts)
      end
    end
  end

  describe "localhost blocking" do
    test "blocks localhost variations when security enabled", %{
      opts: opts,
      agent_id: agent_id
    } do
      localhost_variations = [
        "localhost",
        "LOCALHOST",
        "LocalHost",
        "127.0.0.1",
        "127.0.0.2",
        "127.255.255.255"
      ]

      for host <- localhost_variations do
        url = "http://#{host}/test"
        params = %{url: url, security_check: true}

        assert {:error, :blocked_domain} = Web.execute(params, agent_id, opts),
               "Failed to block localhost variation: #{host}"
      end

      # Test IPv6 with proper bracket notation
      assert {:error, :blocked_domain} =
               Web.execute(%{url: "http://[::1]/test", security_check: true}, agent_id, opts)
    end
  end
end
