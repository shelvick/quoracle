defmodule Quoracle.Skills.SkillsPathConfigTest do
  @moduledoc """
  Tests for configurable skills_path feature.
  Covers ConfigModelSettings v5.0 (R32-R36) and SKILL_Loader v2.0 (R16-R21).
  Part of TEST_SkillsPathConfig spec (feat-20260208-210722, Packet 3).

  ARC Criteria:
  - CONFIG_ModelSettings R32: get_skills_path returns path when configured
  - CONFIG_ModelSettings R33: get_skills_path returns error when not configured
  - CONFIG_ModelSettings R34: set_skills_path persists valid path
  - CONFIG_ModelSettings R35: set_skills_path rejects empty string
  - CONFIG_ModelSettings R36: get_all includes skills_path key
  - SKILL_Loader R16: opts override DB config
  - SKILL_Loader R17: DB config used when no opts
  - SKILL_Loader R18: hardcoded default when nothing configured
  - SKILL_Loader R19: DB error falls through to hardcoded default
  - SKILL_Loader R20: skills_dir expands tilde in DB-configured path
  """

  # DataCase provides DB sandbox isolation per test
  use Quoracle.DataCase, async: true

  alias Quoracle.Models.ConfigModelSettings
  alias Quoracle.Models.TableConsensusConfig
  alias Quoracle.Skills.Loader

  # =============================================================
  # ConfigModelSettings v5.0: get_skills_path/0 (R32-R33)
  # =============================================================

  describe "ConfigModelSettings.get_skills_path/0" do
    @tag :r32
    test "get_skills_path returns path when configured" do
      # R32: WHEN skills_path configured THEN get_skills_path returns {:ok, path}
      {:ok, _} = ConfigModelSettings.set_skills_path("/custom/skills")
      assert {:ok, "/custom/skills"} = ConfigModelSettings.get_skills_path()
    end

    @tag :r33
    test "get_skills_path returns error when not configured" do
      # R33: WHEN skills_path not configured THEN get_skills_path returns {:error, :not_configured}
      assert {:error, :not_configured} = ConfigModelSettings.get_skills_path()
    end
  end

  # =============================================================
  # ConfigModelSettings v5.0: set_skills_path/1 (R34-R35)
  # =============================================================

  describe "ConfigModelSettings.set_skills_path/1" do
    @tag :r34
    test "set_skills_path persists valid path" do
      # R34: WHEN valid path provided THEN set_skills_path persists and returns {:ok, path}
      assert {:ok, "/any/path"} = ConfigModelSettings.set_skills_path("/any/path")
      # Verify round-trip persistence
      assert {:ok, "/any/path"} = ConfigModelSettings.get_skills_path()
    end

    @tag :r35
    test "set_skills_path rejects empty string" do
      # R35: WHEN empty string provided THEN set_skills_path returns {:error, :empty_path}
      assert {:error, :empty_path} = ConfigModelSettings.set_skills_path("")
    end
  end

  # =============================================================
  # ConfigModelSettings v5.0: get_all/0 includes skills_path (R36)
  # =============================================================

  describe "ConfigModelSettings.get_all/0 skills_path" do
    @tag :r36
    test "get_all includes skills_path key with nil when not configured" do
      # R36: WHEN get_all called THEN returns map including skills_path key
      result = ConfigModelSettings.get_all()
      assert Map.has_key?(result, :skills_path)
      assert result.skills_path == nil
    end

    @tag :r36
    test "get_all includes configured skills_path value" do
      {:ok, _} = ConfigModelSettings.set_skills_path("/configured/path")
      result = ConfigModelSettings.get_all()
      assert result.skills_path == "/configured/path"
    end
  end

  # =============================================================
  # SKILL_Loader v2.0: Fallback chain (R16-R19)
  # =============================================================

  describe "Loader.skills_dir/1 fallback chain" do
    @tag :r16
    test "opts skills_path overrides DB config" do
      # R16: WHEN opts contains :skills_path AND DB has different path THEN uses opts value
      {:ok, _} = ConfigModelSettings.set_skills_path("/db/path")
      assert Loader.skills_dir(skills_path: "/opts/path") == "/opts/path"
    end

    @tag :r17
    test "skills_dir uses DB config when no opts" do
      # R17: WHEN no opts :skills_path but DB configured THEN uses DB path
      {:ok, _} = ConfigModelSettings.set_skills_path("/db/path")
      assert Loader.skills_dir() == "/db/path"
    end

    @tag :r18
    test "skills_dir falls back to hardcoded default" do
      # R18: WHEN no opts and DB returns :not_configured THEN uses ~/.quoracle/skills
      # Verify DB returns not_configured (confirms no config interference)
      assert {:error, :not_configured} = ConfigModelSettings.get_skills_path()
      # With nothing configured, Loader falls back to hardcoded default
      assert Loader.skills_dir() == Path.expand("~/.quoracle/skills")
    end

    @tag :r19
    test "DB error falls through to hardcoded default" do
      # R19: WHEN DB has corrupt/invalid skills_path data THEN Loader falls through
      # Distinct from R18: R18 tests no config at all, R19 tests corrupt config
      # Store skills_path key with invalid JSONB structure (wrong key, no "path")
      {:ok, _} = TableConsensusConfig.upsert("skills_path", %{"wrong_key" => "value"})

      # Config layer should report SOME error (not :ok) for structurally invalid data
      # We assert {:error, _reason} without pinning the specific reason,
      # because the Loader must handle ANY error from config gracefully
      result = ConfigModelSettings.get_skills_path()
      assert {:error, _reason} = result

      # Loader falls through to hardcoded default regardless of error type
      assert Loader.skills_dir() == Path.expand("~/.quoracle/skills")
    end
  end

  # =============================================================
  # SKILL_Loader v2.0: Tilde path expansion (R20)
  # =============================================================

  describe "Loader tilde path expansion" do
    @tag :r20
    test "skills_dir expands tilde in DB-configured path" do
      # R20: WHEN DB config contains path with ~ THEN skills_dir returns expanded path
      # Bug: Loader returns raw tilde path from DB, File.dir?("~/...") returns false
      tilde_path = "~/.quoracle_tilde_test_#{System.unique_integer([:positive])}"
      expanded_path = Path.expand(tilde_path)

      {:ok, _} = ConfigModelSettings.set_skills_path(tilde_path)

      # The returned path should be expanded (no literal tilde)
      result = Loader.skills_dir()
      assert result == expanded_path
      # Negative: path must NOT contain literal tilde
      refute String.starts_with?(result, "~")
    end
  end
end
