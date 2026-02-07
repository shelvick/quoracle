defmodule Quoracle.Actions.FileWriteTest do
  @moduledoc """
  Tests for ACTION_FileWrite - File Write/Edit Action
  WorkGroupID: feat-20260107-file-actions
  Packet: 2 (FileWrite with Edit Semantics)

  Covers:
  - R1-R4: Write mode requirements (create, fail existing, parent dirs, bytes)
  - R5-R6: Edit mode basic (single replacement, not found)
  - R7-R8: Edit mode ambiguous (count, replace_all)
  - R9-R11: Edit mode advanced (multiline, file not found, exact match)
  - R12-R15: Error handling (relative path, invalid mode, missing params, permission)
  - R16-R18: Property-based tests (idempotent, portions, count accuracy)
  - R19-R20: Router integration (separate file)
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Quoracle.Actions.FileWrite

  @moduletag :file_actions

  # ===========================================================================
  # Test Setup
  # ===========================================================================
  setup do
    # Create unique temp directory for test files
    temp_dir =
      Path.join([
        System.tmp_dir!(),
        "file_write_test",
        "#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(temp_dir)

    on_exit(fn ->
      File.rm_rf!(temp_dir)
    end)

    {:ok, temp_dir: temp_dir}
  end

  # ===========================================================================
  # R1-R4: Write Mode Requirements
  # ===========================================================================
  describe "R1: write mode creates new file" do
    test "creates new file with content", %{temp_dir: temp_dir} do
      # [UNIT] - WHEN mode=:write and file doesn't exist THEN creates file with content
      path = Path.join(temp_dir, "new_file.txt")

      assert {:ok, result} =
               FileWrite.execute(
                 %{path: path, mode: :write, content: "Hello World"},
                 "agent-1",
                 []
               )

      assert result.action == "file_write"
      assert result.mode == :write
      assert result.created == true
      assert File.read!(path) == "Hello World"
    end
  end

  describe "R2: write mode fails on existing file" do
    test "fails if file exists", %{temp_dir: temp_dir} do
      # [UNIT] - WHEN mode=:write and file exists THEN returns {:error, :file_exists, ...}
      path = Path.join(temp_dir, "existing.txt")
      File.write!(path, "already here")

      assert {:error, {:file_exists, %{path: ^path, hint: hint}}} =
               FileWrite.execute(%{path: path, mode: :write, content: "new"}, "agent-1", [])

      assert hint =~ "edit mode"
      # Original content unchanged
      assert File.read!(path) == "already here"
    end
  end

  describe "R3: write mode creates parent directories" do
    test "creates parent directories", %{temp_dir: temp_dir} do
      # [UNIT] - WHEN mode=:write and parent directory missing THEN creates directories
      path = Path.join([temp_dir, "nested", "deep", "file.txt"])

      assert {:ok, _} =
               FileWrite.execute(
                 %{path: path, mode: :write, content: "nested content"},
                 "agent-1",
                 []
               )

      assert File.exists?(path)
      assert File.read!(path) == "nested content"
    end
  end

  describe "R4: write mode writes correct content" do
    test "writes large content correctly", %{temp_dir: temp_dir} do
      # [UNIT] - WHEN write succeeds THEN file contains expected content
      path = Path.join(temp_dir, "bytes.txt")
      content = String.duplicate("x", 1000)

      assert {:ok, result} =
               FileWrite.execute(
                 %{path: path, mode: :write, content: content},
                 "agent-1",
                 []
               )

      assert result.created == true
      assert File.read!(path) == content
    end
  end

  # ===========================================================================
  # R5-R6: Edit Mode Basic
  # ===========================================================================
  describe "R5: edit mode single replacement" do
    test "replaces single occurrence", %{temp_dir: temp_dir} do
      # [UNIT] - WHEN old_string occurs once THEN replaces with new_string
      path = Path.join(temp_dir, "edit.txt")
      File.write!(path, "Hello World")

      assert {:ok, result} =
               FileWrite.execute(
                 %{path: path, mode: :edit, old_string: "World", new_string: "Universe"},
                 "agent-1",
                 []
               )

      assert result.action == "file_write"
      assert result.mode == :edit
      assert result.replacements == 1
      assert File.read!(path) == "Hello Universe"
    end
  end

  describe "R6: edit mode string not found" do
    test "fails when string not found", %{temp_dir: temp_dir} do
      # [UNIT] - WHEN old_string not in file THEN returns {:error, :string_not_found, ...}
      path = Path.join(temp_dir, "notfound.txt")
      File.write!(path, "Hello World")

      assert {:error, {:string_not_found, %{path: ^path, hint: hint}}} =
               FileWrite.execute(
                 %{path: path, mode: :edit, old_string: "Missing", new_string: "Found"},
                 "agent-1",
                 []
               )

      assert hint =~ "exactly"
      # Original unchanged
      assert File.read!(path) == "Hello World"
    end
  end

  # ===========================================================================
  # R7-R8: Edit Mode Ambiguous
  # ===========================================================================
  describe "R7: edit mode ambiguous match" do
    test "fails on ambiguous match with count", %{temp_dir: temp_dir} do
      # [UNIT] - WHEN old_string occurs >1 time and replace_all=false THEN returns error with count
      path = Path.join(temp_dir, "ambiguous.txt")
      File.write!(path, "foo bar foo baz foo")

      assert {:error, {:ambiguous_match, %{path: ^path, count: 3, hint: hint}}} =
               FileWrite.execute(
                 %{path: path, mode: :edit, old_string: "foo", new_string: "qux"},
                 "agent-1",
                 []
               )

      assert hint =~ "3 occurrences"
      assert hint =~ "replace_all"
      # Original unchanged
      assert File.read!(path) == "foo bar foo baz foo"
    end
  end

  describe "R8: edit mode replace_all" do
    test "replaces all when replace_all=true", %{temp_dir: temp_dir} do
      # [UNIT] - WHEN replace_all=true and old_string occurs N times THEN replaces all N
      path = Path.join(temp_dir, "replace_all.txt")
      File.write!(path, "foo bar foo baz foo")

      assert {:ok, result} =
               FileWrite.execute(
                 %{
                   path: path,
                   mode: :edit,
                   old_string: "foo",
                   new_string: "qux",
                   replace_all: true
                 },
                 "agent-1",
                 []
               )

      assert result.replacements == 3
      assert File.read!(path) == "qux bar qux baz qux"
    end
  end

  # ===========================================================================
  # R9-R11: Edit Mode Advanced
  # ===========================================================================
  describe "R9: edit mode multiline" do
    test "handles multiline old_string", %{temp_dir: temp_dir} do
      # [UNIT] - WHEN old_string contains newlines THEN matches across lines
      path = Path.join(temp_dir, "multiline.txt")
      File.write!(path, "line1\nline2\nline3")

      assert {:ok, _} =
               FileWrite.execute(
                 %{path: path, mode: :edit, old_string: "line1\nline2", new_string: "replaced"},
                 "agent-1",
                 []
               )

      assert File.read!(path) == "replaced\nline3"
    end
  end

  describe "R10: edit mode file not found" do
    test "fails when file doesn't exist", %{temp_dir: temp_dir} do
      # [UNIT] - WHEN mode=:edit and file doesn't exist THEN returns error
      path = Path.join(temp_dir, "nonexistent.txt")

      assert {:error, {:file_not_found, %{path: ^path, hint: hint}}} =
               FileWrite.execute(
                 %{path: path, mode: :edit, old_string: "foo", new_string: "bar"},
                 "agent-1",
                 []
               )

      assert hint =~ "write mode"
    end
  end

  describe "R11: edit mode exact match required" do
    test "requires exact whitespace match", %{temp_dir: temp_dir} do
      # [UNIT] - WHEN old_string differs by whitespace THEN does not match
      path = Path.join(temp_dir, "whitespace.txt")
      # Two spaces between words
      File.write!(path, "hello  world")

      # Single space doesn't match
      assert {:error, {:string_not_found, _}} =
               FileWrite.execute(
                 %{path: path, mode: :edit, old_string: "hello world", new_string: "hi"},
                 "agent-1",
                 []
               )

      # Exact match works
      assert {:ok, _} =
               FileWrite.execute(
                 %{path: path, mode: :edit, old_string: "hello  world", new_string: "hi there"},
                 "agent-1",
                 []
               )

      assert File.read!(path) == "hi there"
    end
  end

  # ===========================================================================
  # R12-R15: Error Handling
  # ===========================================================================
  describe "R12: relative path rejected" do
    test "rejects relative paths" do
      # [UNIT] - WHEN path is relative THEN returns {:error, :relative_path, ...}
      assert {:error, {:relative_path, %{path: "relative.txt"}}} =
               FileWrite.execute(
                 %{path: "relative.txt", mode: :write, content: "test"},
                 "agent-1",
                 []
               )
    end
  end

  describe "R13: invalid mode rejected" do
    test "rejects invalid mode" do
      # [UNIT] - WHEN mode is not :write or :edit THEN returns {:error, :invalid_mode, ...}
      assert {:error, {:invalid_mode, %{mode: :append, hint: hint}}} =
               FileWrite.execute(
                 %{path: "/tmp/test.txt", mode: :append, content: "test"},
                 "agent-1",
                 []
               )

      assert hint =~ "write"
      assert hint =~ "edit"
    end
  end

  describe "R14: missing mode params" do
    test "returns error for missing mode-specific params" do
      # [UNIT] - WHEN mode params missing THEN returns descriptive error
      # Write mode without content
      assert {:error, {:missing_content, _}} =
               FileWrite.execute(%{path: "/tmp/test.txt", mode: :write}, "agent-1", [])

      # Edit mode without old_string
      assert {:error, {:missing_old_string, _}} =
               FileWrite.execute(
                 %{path: "/tmp/test.txt", mode: :edit, new_string: "x"},
                 "agent-1",
                 []
               )

      # Edit mode without new_string
      assert {:error, {:missing_new_string, _}} =
               FileWrite.execute(
                 %{path: "/tmp/test.txt", mode: :edit, old_string: "x"},
                 "agent-1",
                 []
               )
    end
  end

  describe "R15: permission denied" do
    @tag :requires_chmod
    test "returns permission_denied for unwritable paths", %{temp_dir: temp_dir} do
      # [UNIT] - WHEN file/directory not writable THEN returns {:error, :permission_denied, ...}
      unwritable = Path.join(temp_dir, "unwritable")
      File.mkdir_p!(unwritable)
      File.chmod!(unwritable, 0o444)

      on_exit(fn -> File.chmod!(unwritable, 0o755) end)

      path = Path.join(unwritable, "test.txt")

      assert {:error, {:permission_denied, _}} =
               FileWrite.execute(%{path: path, mode: :write, content: "test"}, "agent-1", [])
    end
  end

  # ===========================================================================
  # R16-R18: Property-Based Tests
  # ===========================================================================
  describe "R16: edit is idempotent" do
    property "edit is idempotent after first application", %{temp_dir: temp_dir} do
      # [UNIT] - FOR ANY content THEN edit(edit(content)) with same params produces same result
      # Use non-overlapping character classes to guarantee no pattern recreation:
      # - old: lowercase only, new: uppercase only, prefix/suffix: digits only
      check all(
              prefix <- string(?0..?9, min_length: 3, max_length: 10),
              old <- string(?a..?z, min_length: 2, max_length: 5),
              suffix <- string(?0..?9, min_length: 3, max_length: 10),
              new <- string(?A..?Z, min_length: 2, max_length: 5)
            ) do
        content = prefix <> old <> suffix
        path = Path.join(temp_dir, "idem_#{System.unique_integer([:positive])}.txt")

        # First edit
        File.write!(path, content)

        FileWrite.execute(
          %{path: path, mode: :edit, old_string: old, new_string: new, replace_all: true},
          "agent-1",
          []
        )

        after_first = File.read!(path)

        # Second edit with same params (old_string no longer exists)
        result =
          FileWrite.execute(
            %{path: path, mode: :edit, old_string: old, new_string: new, replace_all: true},
            "agent-1",
            []
          )

        # Either succeeds with 0 replacements or returns string_not_found
        case result do
          {:ok, %{replacements: 0}} -> :ok
          {:error, {:string_not_found, _}} -> :ok
          other -> flunk("Unexpected result: #{inspect(other)}")
        end

        # Content unchanged after second attempt
        assert File.read!(path) == after_first

        File.rm!(path)
      end
    end
  end

  describe "R17: edit only changes matched portions" do
    property "edit only changes matched portions", %{temp_dir: temp_dir} do
      # [UNIT] - FOR ANY replacement THEN only old_string portions change
      # Use non-overlapping character classes to prevent target appearing in prefix/suffix:
      # - prefix/suffix: digits only, target: lowercase only, replacement: uppercase only
      check all(
              prefix <- string(?0..?9, min_length: 3, max_length: 10),
              target <- string(?a..?z, min_length: 2, max_length: 5),
              suffix <- string(?0..?9, min_length: 3, max_length: 10),
              replacement <- string(?A..?Z, min_length: 2, max_length: 5)
            ) do
        content = prefix <> target <> suffix
        path = Path.join(temp_dir, "portions_#{System.unique_integer([:positive])}.txt")
        File.write!(path, content)

        FileWrite.execute(
          %{path: path, mode: :edit, old_string: target, new_string: replacement},
          "agent-1",
          []
        )

        result = File.read!(path)
        assert String.starts_with?(result, prefix)
        assert String.ends_with?(result, suffix)

        File.rm!(path)
      end
    end
  end

  describe "R18: ambiguous match count accuracy" do
    property "ambiguous match count is accurate", %{temp_dir: temp_dir} do
      # [UNIT] - FOR ANY content THEN ambiguous_match count equals actual occurrences
      check all(
              pattern <- string(:alphanumeric, min_length: 2, max_length: 3),
              count <- integer(2..10)
            ) do
        content = Enum.join(List.duplicate(pattern, count), " ")
        path = Path.join(temp_dir, "count_#{System.unique_integer([:positive])}.txt")
        File.write!(path, content)

        {:error, {:ambiguous_match, %{count: reported_count}}} =
          FileWrite.execute(
            %{path: path, mode: :edit, old_string: pattern, new_string: "x"},
            "agent-1",
            []
          )

        assert reported_count == count

        File.rm!(path)
      end
    end
  end

  # ===========================================================================
  # R19-R20: Router Integration - Tested in router_file_actions_test.exs
  # ===========================================================================
  # R19-R20 [INTEGRATION] tests require Router with isolated dependencies.
  # Following existing pattern (router_web_test.exs, router_file_actions_test.exs),
  # Router integration tests are in router_file_actions_test.exs.
  # This file focuses on FileWrite module unit tests (R1-R18).
end
