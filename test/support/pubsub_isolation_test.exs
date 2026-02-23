defmodule Test.PubSubIsolationTest do
  @moduledoc """
  Tests for the PubSubIsolation helper module.
  Verifies isolation and explicit parameter passing without Process dictionary.
  """
  use ExUnit.Case, async: true

  alias Test.PubSubIsolation

  describe "setup_isolated_pubsub/0" do
    test "returns {:ok, unique_atom} with PubSub instance name" do
      {:ok, pubsub} = PubSubIsolation.setup_isolated_pubsub()

      assert is_atom(pubsub)
      assert pubsub |> to_string() |> String.starts_with?("test_pubsub_")
    end

    test "creates unique instance names for multiple calls" do
      {:ok, pubsub1} = PubSubIsolation.setup_isolated_pubsub()
      {:ok, pubsub2} = PubSubIsolation.setup_isolated_pubsub()
      {:ok, pubsub3} = PubSubIsolation.setup_isolated_pubsub()

      assert pubsub1 != pubsub2
      assert pubsub2 != pubsub3
      assert pubsub1 != pubsub3
    end

    test "stores in Process dictionary for backward compatibility" do
      # Clear any existing value
      Process.delete(:test_pubsub)

      {:ok, pubsub} = PubSubIsolation.setup_isolated_pubsub()

      # Temporarily stores for backward compatibility (will be removed in Packet 3)
      assert Process.get(:test_pubsub) == pubsub
    end

    test "created PubSub instance accepts subscriptions" do
      {:ok, pubsub} = PubSubIsolation.setup_isolated_pubsub()

      # Should be able to subscribe to the isolated instance
      assert :ok = Phoenix.PubSub.subscribe(pubsub, "test_topic")
    end

    test "broadcasts work on isolated instance" do
      {:ok, pubsub} = PubSubIsolation.setup_isolated_pubsub()

      Phoenix.PubSub.subscribe(pubsub, "test_topic")
      Phoenix.PubSub.broadcast(pubsub, "test_topic", {:test_message, "data"})

      assert_receive {:test_message, "data"}
    end
  end

  describe "isolation between instances" do
    test "messages don't leak between isolated instances" do
      {:ok, pubsub1} = PubSubIsolation.setup_isolated_pubsub()
      {:ok, pubsub2} = PubSubIsolation.setup_isolated_pubsub()

      # Subscribe to same topic on different instances
      Phoenix.PubSub.subscribe(pubsub1, "shared_topic")
      Phoenix.PubSub.subscribe(pubsub2, "shared_topic")

      # Broadcast to first instance
      Phoenix.PubSub.broadcast(pubsub1, "shared_topic", {:from_pubsub1, "data1"})

      # Should receive on pubsub1
      assert_receive {:from_pubsub1, "data1"}

      # Should NOT receive duplicate (would indicate pubsub2 got it)
      refute_receive {:from_pubsub1, _}, 100

      # Broadcast to second instance
      Phoenix.PubSub.broadcast(pubsub2, "shared_topic", {:from_pubsub2, "data2"})

      # Should receive on pubsub2
      assert_receive {:from_pubsub2, "data2"}

      # Should NOT receive duplicate
      refute_receive {:from_pubsub2, _}, 100
    end
  end

  describe "concurrent test isolation" do
    test "concurrent tests get different instances" do
      # Simulate multiple tests running in parallel
      tasks =
        for _ <- 1..10 do
          Task.async(fn ->
            {:ok, pubsub} = PubSubIsolation.setup_isolated_pubsub()

            # Subscribe and broadcast on own instance
            Phoenix.PubSub.subscribe(pubsub, "concurrent_topic")

            unique_msg = {:test, System.unique_integer()}
            Phoenix.PubSub.broadcast(pubsub, "concurrent_topic", unique_msg)

            # Should receive own message
            assert_receive ^unique_msg

            # Should NOT receive any other messages
            refute_receive {:test, _}, 100

            pubsub
          end)
        end

      # Collect all pubsub names
      pubsub_names = Enum.map(tasks, &Task.await/1)

      # All should be unique
      assert length(pubsub_names) == length(Enum.uniq(pubsub_names))
    end
  end

  describe "subscribe_isolated/2 helper" do
    test "subscribes to topic on isolated instance" do
      {:ok, pubsub} = PubSubIsolation.setup_isolated_pubsub()

      # Use helper to subscribe
      assert :ok = PubSubIsolation.subscribe_isolated(pubsub, "helper_topic")

      # Broadcast to verify subscription
      Phoenix.PubSub.broadcast(pubsub, "helper_topic", {:helper_msg, "data"})

      assert_receive {:helper_msg, "data"}
    end

    test "returns error for invalid pubsub name" do
      # This should fail since :nonexistent_pubsub doesn't exist
      result = PubSubIsolation.subscribe_isolated(:nonexistent_pubsub, "topic")

      assert {:error, _} = result
    end
  end

  describe "usage pattern in actual tests" do
    setup do
      {:ok, pubsub} = PubSubIsolation.setup_isolated_pubsub()
      {:ok, pubsub: pubsub}
    end

    test "setup provides isolated pubsub for test", %{pubsub: pubsub} do
      # This test has its own isolated pubsub from setup
      Phoenix.PubSub.subscribe(pubsub, "setup_topic")
      Phoenix.PubSub.broadcast(pubsub, "setup_topic", {:setup_msg, "test"})

      assert_receive {:setup_msg, "test"}
    end

    test "each test gets fresh isolated instance", %{pubsub: pubsub} do
      # This test gets a different instance than the previous test
      Phoenix.PubSub.subscribe(pubsub, "another_topic")

      # Should not receive messages from other tests
      refute_receive _, 100
    end
  end

  describe "backward compatibility" do
    test "explicit passing works alongside Process dictionary" do
      {:ok, pubsub} = PubSubIsolation.setup_isolated_pubsub()

      # Should work with explicit passing
      Phoenix.PubSub.subscribe(pubsub, "explicit_pass")
      Phoenix.PubSub.broadcast(pubsub, "explicit_pass", {:test, "data"})

      assert_receive {:test, "data"}

      # Process dictionary also set for backward compatibility
      assert Process.get(:test_pubsub) == pubsub
    end
  end
end
