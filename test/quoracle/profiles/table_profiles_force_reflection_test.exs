defmodule Quoracle.Profiles.TableProfilesForceReflectionTest do
  @moduledoc """
  Tests for force_reflection column in TableProfiles.
  Covers TABLE_Profiles v4.0 DB schema requirements.

  WorkGroupID: feat-20260225-forced-reflection
  NodeIDs: [TABLE_Profiles]
  """

  use Quoracle.DataCase, async: true

  alias Quoracle.Profiles.TableProfiles

  describe "force_reflection column" do
    test "force_reflection column exists and accepts boolean true" do
      changeset =
        TableProfiles.changeset(%TableProfiles{}, %{
          name: "test-profile-force-reflection",
          model_pool: ["model-1"],
          capability_groups: [],
          max_refinement_rounds: 4,
          force_reflection: true
        })

      assert changeset.valid?, "Changeset should be valid with force_reflection: true"
      profile = Repo.insert!(changeset)
      assert profile.force_reflection == true
    end

    test "force_reflection column accepts boolean false" do
      changeset =
        TableProfiles.changeset(%TableProfiles{}, %{
          name: "test-profile-no-force",
          model_pool: ["model-1"],
          capability_groups: [],
          max_refinement_rounds: 4,
          force_reflection: false
        })

      assert changeset.valid?, "Changeset should be valid with force_reflection: false"
      profile = Repo.insert!(changeset)
      assert profile.force_reflection == false
    end

    test "force_reflection defaults to false when not provided" do
      changeset =
        TableProfiles.changeset(%TableProfiles{}, %{
          name: "test-profile-default",
          model_pool: ["model-1"],
          capability_groups: [],
          max_refinement_rounds: 4
        })

      assert changeset.valid?
      profile = Repo.insert!(changeset)
      assert profile.force_reflection == false
    end
  end
end
