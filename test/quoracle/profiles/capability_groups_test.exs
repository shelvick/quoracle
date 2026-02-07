defmodule Quoracle.Profiles.CapabilityGroupsTest do
  @moduledoc """
  Tests for PROFILE_CapabilityGroups - pure module defining 5 capability groups.

  Tests cover all ARC requirements R1-R11:
  - R1: groups/0 returns 5 groups in display order
  - R2: group_actions/1 returns correct actions for each group
  - R3: group_actions/1 returns error for invalid group
  - R4: allowed_actions_for_groups/1 with empty list returns base actions
  - R5: allowed_actions_for_groups/1 with single group adds group actions
  - R6: allowed_actions_for_groups/1 deduplicates actions across groups
  - R7: allowed_actions_for_groups/1 with all groups returns 19 unique actions
  - R8: action_allowed?/2 returns boolean for action/groups combinations
  - R9: base_actions/0 returns 7 always-allowed actions
  - R10: get_group_description/1 returns description for each group
  - R11: role-gated actions never in allowed_actions_for_groups
  """

  use ExUnit.Case, async: true

  alias Quoracle.Profiles.CapabilityGroups

  # Expected action groups from spec (v3.0)
  # 7 base + 2 skill actions = 9 always_allowed (search_skills removed)
  @always_allowed [
    :wait,
    :orient,
    :todo,
    :send_message,
    :fetch_web,
    :answer_engine,
    :generate_images,
    # Skill actions (v27.0)
    :learn_skills,
    :create_skill
  ]

  @hierarchy_actions [:spawn_child, :dismiss_child, :adjust_budget]

  @local_execution_actions [
    :execute_shell,
    :call_mcp,
    :record_cost,
    :search_secrets,
    :generate_secret
  ]

  @file_read_actions [:file_read]

  @file_write_actions [:file_write, :search_secrets, :generate_secret]

  @external_api_actions [:call_api, :record_cost, :search_secrets, :generate_secret]

  @all_groups [:file_read, :file_write, :external_api, :hierarchy, :local_execution]

  describe "groups/0" do
    # R1: Groups Returns 5 Groups
    test "groups/0 returns all 5 capability groups in display order" do
      groups = CapabilityGroups.groups()

      assert length(groups) == 5
      assert :file_read in groups
      assert :file_write in groups
      assert :external_api in groups
      assert :hierarchy in groups
      assert :local_execution in groups

      # Verify order: safest first (file_read, file_write, external_api, hierarchy, local_execution)
      assert groups == [:file_read, :file_write, :external_api, :hierarchy, :local_execution]
    end
  end

  describe "group_actions/1" do
    # R2: Group Actions Returns Correct Actions
    test "group_actions/1 returns correct actions for each group" do
      # file_read group
      assert {:ok, file_read_actions} = CapabilityGroups.group_actions(:file_read)
      assert file_read_actions == @file_read_actions

      # file_write group
      assert {:ok, file_write_actions} = CapabilityGroups.group_actions(:file_write)
      assert Enum.sort(file_write_actions) == Enum.sort(@file_write_actions)

      # external_api group
      assert {:ok, external_api_actions} = CapabilityGroups.group_actions(:external_api)
      assert Enum.sort(external_api_actions) == Enum.sort(@external_api_actions)

      # hierarchy group
      assert {:ok, hierarchy_actions} = CapabilityGroups.group_actions(:hierarchy)
      assert hierarchy_actions == @hierarchy_actions

      # local_execution group
      assert {:ok, local_execution_actions} = CapabilityGroups.group_actions(:local_execution)
      assert Enum.sort(local_execution_actions) == Enum.sort(@local_execution_actions)
    end

    # R3: Group Actions Handles Invalid
    test "group_actions/1 returns error for invalid group" do
      assert {:error, :invalid_group} = CapabilityGroups.group_actions(:invalid)
      assert {:error, :invalid_group} = CapabilityGroups.group_actions(:unknown)
      assert {:error, :invalid_group} = CapabilityGroups.group_actions("file_read")
      assert {:error, :invalid_group} = CapabilityGroups.group_actions(:full)
      assert {:error, :invalid_group} = CapabilityGroups.group_actions(:restricted)
    end
  end

  describe "allowed_actions_for_groups/1" do
    # R4: Allowed Actions Empty Groups
    test "allowed_actions_for_groups/1 with empty list returns base actions only" do
      assert {:ok, allowed} = CapabilityGroups.allowed_actions_for_groups([])

      # Should have exactly 11 base actions (7 original + 2 skills + 2 batch actions)
      assert length(allowed) == 11

      # Should include all base actions
      for action <- @always_allowed do
        assert action in allowed, "Expected #{action} in base actions"
      end

      # Should NOT include any group-specific actions
      refute :file_read in allowed
      refute :file_write in allowed
      refute :spawn_child in allowed
      refute :execute_shell in allowed
      refute :call_api in allowed
    end

    # R5: Allowed Actions Single Group
    test "allowed_actions_for_groups/1 with single group adds group actions" do
      # Test with hierarchy group
      assert {:ok, allowed} = CapabilityGroups.allowed_actions_for_groups([:hierarchy])

      # Should have base (11) + hierarchy (3) = 14 actions
      assert length(allowed) == 14

      # Should include all base actions
      for action <- @always_allowed do
        assert action in allowed
      end

      # Should include hierarchy actions
      for action <- @hierarchy_actions do
        assert action in allowed, "Expected #{action} in hierarchy group"
      end

      # Should NOT include other group actions
      refute :execute_shell in allowed
      refute :file_read in allowed
      refute :call_api in allowed
    end

    test "allowed_actions_for_groups/1 with file_read only enables file reading" do
      assert {:ok, allowed} = CapabilityGroups.allowed_actions_for_groups([:file_read])

      # Should have base (11) + file_read (1) = 12 actions
      assert length(allowed) == 12

      # Should include file_read
      assert :file_read in allowed

      # Should NOT include file_write (separate group)
      refute :file_write in allowed
    end

    # R6: Allowed Actions Multiple Groups Deduplicates
    test "allowed_actions_for_groups/1 deduplicates actions across groups" do
      # local_execution and external_api both have record_cost, search_secrets, generate_secret
      assert {:ok, allowed} =
               CapabilityGroups.allowed_actions_for_groups([:local_execution, :external_api])

      # Count occurrences of shared actions
      record_cost_count = Enum.count(allowed, &(&1 == :record_cost))
      search_secrets_count = Enum.count(allowed, &(&1 == :search_secrets))
      generate_secret_count = Enum.count(allowed, &(&1 == :generate_secret))

      assert record_cost_count == 1, "record_cost should appear exactly once"
      assert search_secrets_count == 1, "search_secrets should appear exactly once"
      assert generate_secret_count == 1, "generate_secret should appear exactly once"

      # local_execution: 5 unique + external_api: 4 unique - 3 shared + base: 11 = 17
      # Actually: base (11) + local_exec unique (2: execute_shell, call_mcp)
      #                     + external_api unique (1: call_api)
      #                     + shared (3: record_cost, search_secrets, generate_secret) = 17
      assert length(allowed) == 17
    end

    test "allowed_actions_for_groups/1 deduplicates file_write and external_api shared actions" do
      # file_write and external_api share search_secrets, generate_secret
      assert {:ok, allowed} =
               CapabilityGroups.allowed_actions_for_groups([:file_write, :external_api])

      search_secrets_count = Enum.count(allowed, &(&1 == :search_secrets))
      generate_secret_count = Enum.count(allowed, &(&1 == :generate_secret))

      assert search_secrets_count == 1
      assert generate_secret_count == 1

      # base (11) + file_write unique (1: file_write)
      #          + external_api unique (2: call_api, record_cost)
      #          + shared (2: search_secrets, generate_secret) = 16
      assert length(allowed) == 16
    end

    # R7: Allowed Actions All Groups
    test "allowed_actions_for_groups/1 with all groups returns 21 unique actions" do
      assert {:ok, allowed} = CapabilityGroups.allowed_actions_for_groups(@all_groups)

      # Should have exactly 21 unique actions:
      # base (9) + hierarchy (3) + local_exec unique (2) + file_read (1) + file_write unique (1) + external_api unique (1) + shared (3)
      assert length(allowed) == 22

      # All unique actions should be present
      expected_all_actions =
        @always_allowed ++
          @hierarchy_actions ++
          [:execute_shell, :call_mcp] ++
          [:file_read, :file_write] ++
          [:call_api, :record_cost, :search_secrets, :generate_secret]

      for action <- expected_all_actions do
        assert action in allowed, "Expected #{action} in all groups"
      end
    end

    test "allowed_actions_for_groups/1 returns error for invalid groups in list" do
      assert {:error, :invalid_group} =
               CapabilityGroups.allowed_actions_for_groups([:file_read, :invalid])

      assert {:error, :invalid_group} =
               CapabilityGroups.allowed_actions_for_groups([:full])

      assert {:error, :invalid_group} =
               CapabilityGroups.allowed_actions_for_groups(["file_read"])
    end

    test "allowed_actions_for_groups/1 returns error for non-list input" do
      assert {:error, :invalid_group} = CapabilityGroups.allowed_actions_for_groups(:file_read)
      assert {:error, :invalid_group} = CapabilityGroups.allowed_actions_for_groups("file_read")
      assert {:error, :invalid_group} = CapabilityGroups.allowed_actions_for_groups(nil)
    end
  end

  describe "action_allowed?/2" do
    # R8: Action Allowed Predicate
    test "action_allowed?/2 returns boolean for action/groups combinations" do
      # Always allowed actions should be allowed with empty groups
      for action <- @always_allowed do
        assert CapabilityGroups.action_allowed?(action, []) == true,
               "Expected #{action} to be allowed with empty groups"
      end

      # Hierarchy actions need :hierarchy group
      for action <- @hierarchy_actions do
        assert CapabilityGroups.action_allowed?(action, []) == false
        assert CapabilityGroups.action_allowed?(action, [:hierarchy]) == true
      end

      # File read needs :file_read group
      assert CapabilityGroups.action_allowed?(:file_read, []) == false
      assert CapabilityGroups.action_allowed?(:file_read, [:file_read]) == true

      # File write needs :file_write group
      assert CapabilityGroups.action_allowed?(:file_write, []) == false
      assert CapabilityGroups.action_allowed?(:file_write, [:file_write]) == true

      # File read does NOT enable file write
      assert CapabilityGroups.action_allowed?(:file_write, [:file_read]) == false
    end

    test "action_allowed?/2 returns false for invalid capability_groups" do
      refute CapabilityGroups.action_allowed?(:wait, :not_a_list)
      refute CapabilityGroups.action_allowed?(:execute_shell, "hierarchy")
      refute CapabilityGroups.action_allowed?(:file_read, nil)
    end

    test "action_allowed?/2 returns false for unknown actions" do
      refute CapabilityGroups.action_allowed?(:unknown_action, [])
      refute CapabilityGroups.action_allowed?(:not_an_action, @all_groups)
    end

    test "action_allowed?/2 matches allowed_actions_for_groups results" do
      # For each group combination, verify action_allowed? matches allowed_actions_for_groups
      test_cases = [
        [],
        [:file_read],
        [:hierarchy],
        [:local_execution],
        [:file_read, :file_write],
        @all_groups
      ]

      for groups <- test_cases do
        {:ok, allowed} = CapabilityGroups.allowed_actions_for_groups(groups)

        for action <- allowed do
          assert CapabilityGroups.action_allowed?(action, groups),
                 "#{action} should be allowed for groups #{inspect(groups)}"
        end
      end
    end
  end

  describe "base_actions/0" do
    # R9: Base Actions Returns 11 (7 original + 2 skills + 2 batch actions)
    test "base_actions/0 returns 11 always-allowed actions" do
      base = CapabilityGroups.base_actions()

      assert length(base) == 11

      expected = [
        :wait,
        :orient,
        :todo,
        :send_message,
        :fetch_web,
        :answer_engine,
        :generate_images
      ]

      for action <- expected do
        assert action in base, "Expected #{action} in base_actions"
      end
    end

    test "base_actions/0 does NOT include record_cost (moved to groups)" do
      base = CapabilityGroups.base_actions()

      refute :record_cost in base, "record_cost should NOT be in base_actions (now in groups)"
    end

    test "base_actions/0 does NOT include search_secrets or generate_secret (moved to groups)" do
      base = CapabilityGroups.base_actions()

      refute :search_secrets in base, "search_secrets should NOT be in base_actions"
      refute :generate_secret in base, "generate_secret should NOT be in base_actions"
    end
  end

  describe "get_group_description/1" do
    # R10: Group Descriptions
    test "get_group_description/1 returns description for each group" do
      for group <- @all_groups do
        assert {:ok, desc} = CapabilityGroups.get_group_description(group)
        assert is_binary(desc)
        assert String.length(desc) > 10
      end
    end

    test "get_group_description/1 returns unique descriptions for each group" do
      descriptions =
        for group <- @all_groups do
          {:ok, desc} = CapabilityGroups.get_group_description(group)
          desc
        end

      # All descriptions should be unique
      assert length(Enum.uniq(descriptions)) == 5
    end

    test "get_group_description/1 returns error for invalid group" do
      assert {:error, :invalid_group} = CapabilityGroups.get_group_description(:invalid)
      assert {:error, :invalid_group} = CapabilityGroups.get_group_description(:full)
      assert {:error, :invalid_group} = CapabilityGroups.get_group_description("file_read")
    end

    test "get_group_description/1 descriptions match spec-defined content" do
      # Spec defines exact descriptions - assert exact matches
      {:ok, file_read_desc} = CapabilityGroups.get_group_description(:file_read)
      assert file_read_desc == "Read files from the filesystem"

      {:ok, file_write_desc} = CapabilityGroups.get_group_description(:file_write)
      assert file_write_desc == "Write and edit files on the filesystem"

      {:ok, hierarchy_desc} = CapabilityGroups.get_group_description(:hierarchy)
      assert hierarchy_desc == "Spawn and manage child agents"

      {:ok, local_exec_desc} = CapabilityGroups.get_group_description(:local_execution)
      assert local_exec_desc == "Execute shell commands and MCP calls"

      {:ok, external_api_desc} = CapabilityGroups.get_group_description(:external_api)
      assert external_api_desc == "Make HTTP requests to external APIs"
    end
  end

  describe "read-only pattern (file_read without file_write)" do
    test "file_read group enables reading but not writing" do
      assert {:ok, allowed} = CapabilityGroups.allowed_actions_for_groups([:file_read])

      assert :file_read in allowed
      refute :file_write in allowed
      refute :search_secrets in allowed
      refute :generate_secret in allowed
    end

    test "file_write group enables writing AND secrets (but not reading)" do
      assert {:ok, allowed} = CapabilityGroups.allowed_actions_for_groups([:file_write])

      assert :file_write in allowed
      assert :search_secrets in allowed
      assert :generate_secret in allowed
      refute :file_read in allowed
    end

    test "both file groups together enable full file access" do
      assert {:ok, allowed} =
               CapabilityGroups.allowed_actions_for_groups([:file_read, :file_write])

      assert :file_read in allowed
      assert :file_write in allowed
      assert :search_secrets in allowed
      assert :generate_secret in allowed
    end
  end

  describe "action placement verification" do
    test "record_cost is in local_execution and external_api groups" do
      {:ok, local_exec} = CapabilityGroups.group_actions(:local_execution)
      {:ok, external_api} = CapabilityGroups.group_actions(:external_api)

      assert :record_cost in local_exec
      assert :record_cost in external_api
    end

    test "record_cost is NOT in base actions" do
      base = CapabilityGroups.base_actions()
      refute :record_cost in base
    end

    test "search_secrets and generate_secret are in local_execution, external_api, and file_write" do
      {:ok, local_exec} = CapabilityGroups.group_actions(:local_execution)
      {:ok, external_api} = CapabilityGroups.group_actions(:external_api)
      {:ok, file_write} = CapabilityGroups.group_actions(:file_write)

      for action <- [:search_secrets, :generate_secret] do
        assert action in local_exec, "#{action} should be in local_execution"
        assert action in external_api, "#{action} should be in external_api"
        assert action in file_write, "#{action} should be in file_write"
      end
    end

    test "search_secrets and generate_secret are NOT in file_read or hierarchy" do
      {:ok, file_read} = CapabilityGroups.group_actions(:file_read)
      {:ok, hierarchy} = CapabilityGroups.group_actions(:hierarchy)

      for action <- [:search_secrets, :generate_secret] do
        refute action in file_read, "#{action} should NOT be in file_read"
        refute action in hierarchy, "#{action} should NOT be in hierarchy"
      end
    end
  end
end
