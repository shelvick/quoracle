defmodule Quoracle.Profiles.ResolverForceReflectionTest do
  @moduledoc """
  Tests for force_reflection in Resolver (profile snapshot).
  WorkGroupID: feat-20260225-forced-reflection
  """
  use Quoracle.DataCase, async: true
  alias Quoracle.Profiles.Resolver
  alias Quoracle.Profiles.TableProfiles

  test "resolver includes force_reflection in profile_data" do
    profile_name = "force_reflection_test_#{System.unique_integer([:positive])}"

    _profile =
      %TableProfiles{}
      |> TableProfiles.changeset(%{
        name: profile_name,
        description: "test",
        model_pool: ["model-1"],
        capability_groups: [],
        max_refinement_rounds: 4,
        force_reflection: true
      })
      |> Repo.insert!()

    {:ok, data} = Resolver.resolve(profile_name)
    assert data.force_reflection == true
  end

  test "to_config_fields includes force_reflection" do
    data = %{
      name: "test",
      description: "test",
      model_pool: ["model-1"],
      capability_groups: [],
      max_refinement_rounds: 4,
      force_reflection: true
    }

    config = Resolver.to_config_fields(data)
    assert config.force_reflection == true
  end
end
