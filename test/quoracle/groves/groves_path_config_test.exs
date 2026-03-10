defmodule Quoracle.Groves.GrovesPathConfigTest do
  @moduledoc """
  Tests for configurable groves_path feature.
  Covers ConfigModelSettings v6.0 (R37-R42).
  Part of wip-20260222-grove-bootstrap, Packet 3 (Config + Backend Extensions).

  ARC Criteria:
  - CONFIG_ModelSettings R37: get_groves_path returns configured path
  - CONFIG_ModelSettings R38: get_groves_path returns error when not configured
  - CONFIG_ModelSettings R39: set_groves_path stores path in DB
  - CONFIG_ModelSettings R40: set_groves_path rejects empty string
  - CONFIG_ModelSettings R41: delete_groves_path removes config
  - CONFIG_ModelSettings R42: get_all includes groves_path key
  """

  # DataCase provides DB sandbox isolation per test
  use Quoracle.DataCase, async: true

  @moduletag :feat_grove_system

  alias Quoracle.Models.ConfigModelSettings
  alias Quoracle.Models.TableConsensusConfig

  # =============================================================
  # ConfigModelSettings v6.0: get_groves_path/0 (R37-R38)
  # =============================================================

  describe "ConfigModelSettings.get_groves_path/0" do
    @tag :r37
    test "R37: get_groves_path returns configured path" do
      # R37: WHEN groves_path set in DB THEN get_groves_path returns {:ok, path}
      {:ok, _} = ConfigModelSettings.set_groves_path("/custom/groves")
      assert {:ok, "/custom/groves"} = ConfigModelSettings.get_groves_path()
    end

    @tag :r38
    test "R38: get_groves_path returns error when not configured" do
      # R38: WHEN groves_path not in DB THEN get_groves_path returns {:error, :not_configured}
      assert {:error, :not_configured} = ConfigModelSettings.get_groves_path()
    end

    test "get_groves_path returns error for corrupt data" do
      # Edge case: JSONB stored with wrong key structure
      {:ok, _} = TableConsensusConfig.upsert("groves_path", %{"wrong_key" => "value"})

      result = ConfigModelSettings.get_groves_path()
      assert {:error, _reason} = result
    end
  end

  # =============================================================
  # ConfigModelSettings v6.0: set_groves_path/1 (R39-R40)
  # =============================================================

  describe "ConfigModelSettings.set_groves_path/1" do
    @tag :r39
    test "R39: set_groves_path stores path in DB" do
      # R39: WHEN set_groves_path called with valid path THEN stores and returns {:ok, path}
      assert {:ok, "/any/groves/path"} = ConfigModelSettings.set_groves_path("/any/groves/path")
      # Verify round-trip persistence
      assert {:ok, "/any/groves/path"} = ConfigModelSettings.get_groves_path()
    end

    @tag :r40
    test "R40: set_groves_path rejects empty string" do
      # R40: WHEN set_groves_path called with "" THEN returns {:error, :empty_path}
      assert {:error, :empty_path} = ConfigModelSettings.set_groves_path("")
    end

    test "set_groves_path overwrites previous value" do
      {:ok, _} = ConfigModelSettings.set_groves_path("/first/path")
      {:ok, _} = ConfigModelSettings.set_groves_path("/second/path")
      assert {:ok, "/second/path"} = ConfigModelSettings.get_groves_path()
    end
  end

  # =============================================================
  # ConfigModelSettings v6.0: delete_groves_path/0 (R41)
  # =============================================================

  describe "ConfigModelSettings.delete_groves_path/0" do
    @tag :r41
    test "R41: delete_groves_path removes config" do
      # R41: WHEN delete_groves_path called THEN removes from DB
      {:ok, _} = ConfigModelSettings.set_groves_path("/to/delete")
      assert {:ok, "/to/delete"} = ConfigModelSettings.get_groves_path()

      {:ok, _} = ConfigModelSettings.delete_groves_path()
      assert {:error, :not_configured} = ConfigModelSettings.get_groves_path()
    end

    test "delete_groves_path returns error when not configured" do
      assert {:error, :not_found} = ConfigModelSettings.delete_groves_path()
    end
  end

  # =============================================================
  # ConfigModelSettings v6.0: get_all/0 includes groves_path (R42)
  # =============================================================

  describe "ConfigModelSettings.get_all/0 groves_path" do
    @tag :r42
    test "R42: get_all includes groves_path key with nil when not configured" do
      # R42: WHEN get_all called THEN returned map includes groves_path key
      result = ConfigModelSettings.get_all()
      assert Map.has_key?(result, :groves_path)
      assert result.groves_path == nil
    end

    @tag :r42
    test "R42: get_all includes configured groves_path value" do
      {:ok, _} = ConfigModelSettings.set_groves_path("/configured/groves")
      result = ConfigModelSettings.get_all()
      assert result.groves_path == "/configured/groves"
    end
  end
end
