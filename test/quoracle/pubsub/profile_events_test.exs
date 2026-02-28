defmodule Quoracle.PubSub.ProfileEventsTest do
  use ExUnit.Case, async: true

  alias Quoracle.PubSub.AgentEvents

  setup do
    pubsub = :"test_profile_pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub})

    profile_name = "profile-#{System.unique_integer([:positive])}"

    %{pubsub: pubsub, profile_name: profile_name}
  end

  describe "broadcast_profile_updated/3" do
    test "broadcast_profile_updated publishes to profile-specific topic", %{
      pubsub: pubsub,
      profile_name: profile_name
    } do
      :ok = Phoenix.PubSub.subscribe(pubsub, "profiles:#{profile_name}:updated")

      profile_data = %{
        name: profile_name,
        max_refinement_rounds: 7,
        profile_description: "Updated description"
      }

      assert :ok = AgentEvents.broadcast_profile_updated(profile_name, profile_data, pubsub)
      assert_receive {:profile_updated, payload}, 1_000
      assert payload == profile_data
    end
  end

  describe "subscribe_to_profile/2" do
    test "subscribe_to_profile enables receiving profile update messages", %{
      pubsub: pubsub,
      profile_name: profile_name
    } do
      assert :ok = AgentEvents.subscribe_to_profile(profile_name, pubsub)

      profile_data = %{name: profile_name, force_reflection: true}

      :ok =
        Phoenix.PubSub.broadcast(
          pubsub,
          "profiles:#{profile_name}:updated",
          {:profile_updated, profile_data}
        )

      assert_receive {:profile_updated, payload}, 1_000
      assert payload == profile_data
    end
  end

  describe "unsubscribe_from_profile/2" do
    test "unsubscribe_from_profile stops receiving profile update messages", %{
      pubsub: pubsub,
      profile_name: profile_name
    } do
      assert :ok = AgentEvents.subscribe_to_profile(profile_name, pubsub)
      assert :ok = AgentEvents.unsubscribe_from_profile(profile_name, pubsub)

      profile_data = %{name: profile_name, profile_description: "after unsubscribe"}

      :ok =
        Phoenix.PubSub.broadcast(
          pubsub,
          "profiles:#{profile_name}:updated",
          {:profile_updated, profile_data}
        )

      refute_receive {:profile_updated, ^profile_data}, 200
    end
  end
end
