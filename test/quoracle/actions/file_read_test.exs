defmodule Quoracle.Actions.FileReadTest do
  @moduledoc """
  Tests for ACTION_FileRead - File Read Action
  WorkGroupID: feat-20260107-file-actions
  Packet: 1 (FileRead Foundation)

  Covers:
  - R1-R6: Functional requirements (reading, limits, offsets, truncation)
  - R7-R11: Error handling (not found, relative path, binary, directory, permission)
  - R12-R14: Property-based tests (offset validation, limit capping, line numbers)
  - R15: Router integration
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Quoracle.Actions.FileRead

  @moduletag :file_actions

  # ===========================================================================
  # Test Setup
  # ===========================================================================
  setup do
    # Create unique temp directory for test files
    temp_dir =
      Path.join([
        System.tmp_dir!(),
        "file_read_test",
        "#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(temp_dir)

    on_exit(fn ->
      File.rm_rf!(temp_dir)
    end)

    {:ok, temp_dir: temp_dir}
  end

  # ===========================================================================
  # R1: Read Existing File
  # ===========================================================================
  describe "R1: read existing file" do
    test "reads existing file with line numbers", %{temp_dir: temp_dir} do
      # [UNIT] - WHEN execute called with valid path IF file exists THEN returns content with line numbers
      path = Path.join(temp_dir, "#{System.unique_integer([:positive])}.txt")
      File.write!(path, "line one\nline two\nline three")

      assert {:ok, result} = FileRead.execute(%{path: path}, "agent-1", [])

      assert result.action == "file_read"
      assert result.path == path
      assert result.content =~ "1\tline one"
      assert result.content =~ "2\tline two"
      assert result.content =~ "3\tline three"
    end

    test "reads empty file", %{temp_dir: temp_dir} do
      # [UNIT] - WHEN execute called with empty file THEN returns empty content
      # Empty file has no actual content lines, so lines_read should be 0
      path = Path.join(temp_dir, "#{System.unique_integer([:positive])}.txt")
      File.write!(path, "")

      assert {:ok, result} = FileRead.execute(%{path: path}, "agent-1", [])

      assert result.action == "file_read"
      assert result.content == ""
    end

    test "reads single line file", %{temp_dir: temp_dir} do
      # [UNIT] - WHEN execute called with single line file THEN returns that line
      path = Path.join(temp_dir, "#{System.unique_integer([:positive])}.txt")
      File.write!(path, "only line")

      assert {:ok, result} = FileRead.execute(%{path: path}, "agent-1", [])

      assert result.content =~ "1\tonly line"
    end
  end

  # ===========================================================================
  # R2: Default Limit Applied
  # ===========================================================================
  describe "R2: default limit" do
    test "applies default 2000 line limit", %{temp_dir: temp_dir} do
      # [UNIT] - WHEN execute called without limit IF file has >2000 lines THEN returns first 2000 lines
      path = Path.join(temp_dir, "#{System.unique_integer([:positive])}.txt")
      content = Enum.map_join(1..3000, "\n", &"line #{&1}")
      File.write!(path, content)

      assert {:ok, result} = FileRead.execute(%{path: path}, "agent-1", [])

      assert result.truncated == true
    end

    test "does not truncate files under limit", %{temp_dir: temp_dir} do
      # [UNIT] - WHEN execute called IF file has <2000 lines THEN returns all lines
      path = Path.join(temp_dir, "#{System.unique_integer([:positive])}.txt")
      content = Enum.map_join(1..100, "\n", &"line #{&1}")
      File.write!(path, content)

      assert {:ok, result} = FileRead.execute(%{path: path}, "agent-1", [])

      assert result.truncated == false
    end
  end

  # ===========================================================================
  # R3-R5: Offset and Limit
  # ===========================================================================
  describe "R3: offset parameter" do
    test "respects offset parameter", %{temp_dir: temp_dir} do
      # [UNIT] - WHEN execute called with offset=100 IF file has 200 lines THEN returns lines 100-200
      path = Path.join(temp_dir, "#{System.unique_integer([:positive])}.txt")
      content = Enum.map_join(1..200, "\n", &"line #{&1}")
      File.write!(path, content)

      assert {:ok, result} = FileRead.execute(%{path: path, offset: 100}, "agent-1", [])

      assert result.content =~ "100\tline 100"
      # Use start anchor to avoid matching "199\t" which contains "99\t"
      refute result.content =~ ~r/^99\t/m
    end

    test "offset at file end returns empty", %{temp_dir: temp_dir} do
      # [UNIT] - WHEN offset > total lines THEN returns empty content
      path = Path.join(temp_dir, "#{System.unique_integer([:positive])}.txt")
      content = Enum.map_join(1..10, "\n", &"line #{&1}")
      File.write!(path, content)

      assert {:ok, result} = FileRead.execute(%{path: path, offset: 20}, "agent-1", [])

      assert result.content == ""
    end
  end

  describe "R4: limit parameter" do
    test "respects limit parameter", %{temp_dir: temp_dir} do
      # [UNIT] - WHEN execute called with limit=50 IF file has 200 lines THEN returns first 50 lines
      path = Path.join(temp_dir, "#{System.unique_integer([:positive])}.txt")
      content = Enum.map_join(1..200, "\n", &"line #{&1}")
      File.write!(path, content)

      assert {:ok, result} = FileRead.execute(%{path: path, limit: 50}, "agent-1", [])

      assert result.truncated == true
    end
  end

  describe "R5: offset + limit combined" do
    test "combines offset and limit correctly", %{temp_dir: temp_dir} do
      # [UNIT] - WHEN execute called with offset=50, limit=25 THEN returns lines 50-74
      path = Path.join(temp_dir, "#{System.unique_integer([:positive])}.txt")
      content = Enum.map_join(1..100, "\n", &"line #{&1}")
      File.write!(path, content)

      assert {:ok, result} = FileRead.execute(%{path: path, offset: 50, limit: 25}, "agent-1", [])

      assert result.content =~ "50\tline 50"
      assert result.content =~ "74\tline 74"
      refute result.content =~ "75\t"
    end
  end

  # ===========================================================================
  # R6: Line Truncation
  # ===========================================================================
  describe "R6: line truncation" do
    test "truncates long lines with indicator", %{temp_dir: temp_dir} do
      # [UNIT] - WHEN line exceeds 2000 chars THEN truncates with indicator
      path = Path.join(temp_dir, "#{System.unique_integer([:positive])}.txt")
      long_line = String.duplicate("x", 3000)
      File.write!(path, long_line)

      assert {:ok, result} = FileRead.execute(%{path: path}, "agent-1", [])

      assert result.content =~ "... [truncated]"
      assert byte_size(result.content) < 3000
    end

    test "does not truncate lines under limit", %{temp_dir: temp_dir} do
      # [UNIT] - WHEN line under 2000 chars THEN no truncation
      path = Path.join(temp_dir, "#{System.unique_integer([:positive])}.txt")
      normal_line = String.duplicate("x", 100)
      File.write!(path, normal_line)

      assert {:ok, result} = FileRead.execute(%{path: path}, "agent-1", [])

      refute result.content =~ "[truncated]"
    end
  end

  # ===========================================================================
  # R7-R11: Error Handling
  # ===========================================================================
  describe "R7: file not found" do
    test "returns file_not_found for missing file" do
      # [UNIT] - WHEN path does not exist THEN returns {:error, {:file_not_found, %{path: ...}}}
      missing_path =
        Path.join(System.tmp_dir!(), "nonexistent_#{System.unique_integer([:positive])}.txt")

      assert {:error, {:file_not_found, %{path: ^missing_path}}} =
               FileRead.execute(%{path: missing_path}, "agent-1", [])
    end
  end

  describe "R8: relative path rejected" do
    test "rejects relative paths with hint" do
      # [UNIT] - WHEN path is relative THEN returns {:error, {:relative_path, %{path: ..., hint: ...}}}
      assert {:error, {:relative_path, %{path: "relative.txt", hint: hint}}} =
               FileRead.execute(%{path: "relative.txt"}, "agent-1", [])

      assert hint =~ "absolute"
    end

    test "rejects relative path with dots" do
      # [UNIT] - WHEN path starts with ../ THEN returns error
      assert {:error, {:relative_path, _}} =
               FileRead.execute(%{path: "../foo/bar.txt"}, "agent-1", [])
    end
  end

  describe "R9: binary file rejected" do
    test "rejects binary files", %{temp_dir: temp_dir} do
      # [UNIT] - WHEN file contains null bytes THEN returns {:error, {:binary_file, ...}}
      path = Path.join(temp_dir, "#{System.unique_integer([:positive])}.dat")
      # Contains null bytes (common in binary files)
      File.write!(path, <<0, 1, 2, 3, 0, 5>>)

      assert {:error, {:binary_file, %{path: ^path, hint: hint}}} =
               FileRead.execute(%{path: path}, "agent-1", [])

      assert is_binary(hint)
    end
  end

  describe "R10: directory rejected" do
    test "rejects directory paths", %{temp_dir: temp_dir} do
      # [UNIT] - WHEN path is directory THEN returns {:error, {:is_directory, ...}}
      assert {:error, {:is_directory, %{path: ^temp_dir}}} =
               FileRead.execute(%{path: temp_dir}, "agent-1", [])
    end
  end

  describe "R11: permission denied" do
    @tag :requires_chmod
    test "returns permission_denied for unreadable files", %{temp_dir: temp_dir} do
      # [UNIT] - WHEN file not readable THEN returns {:error, {:permission_denied, ...}}
      path = Path.join(temp_dir, "#{System.unique_integer([:positive])}.txt")
      File.write!(path, "secret")
      File.chmod!(path, 0o000)

      on_exit(fn -> File.chmod!(path, 0o644) end)

      assert {:error, {:permission_denied, %{path: ^path}}} =
               FileRead.execute(%{path: path}, "agent-1", [])
    end
  end

  # ===========================================================================
  # R12-R14: Property-Based Tests
  # ===========================================================================
  describe "R12: offset validation" do
    property "rejects non-positive offsets" do
      # [UNIT] - WHEN offset < 1 THEN returns error
      # Validation happens before file access, so path doesn't need to exist
      check all(offset <- integer(-100..0)) do
        path =
          Path.join(
            System.tmp_dir!(),
            "offset_validation_#{System.unique_integer([:positive])}.txt"
          )

        result = FileRead.execute(%{path: path, offset: offset}, "agent-1", [])
        assert {:error, :invalid_offset} = result
      end
    end
  end

  describe "R13: limit capping" do
    property "caps limit at 2000", %{temp_dir: temp_dir} do
      # [UNIT] - WHEN limit > 2000 THEN caps at 2000
      # Module should cap the limit internally, never returning more than 2000 lines
      check all(limit <- integer(2001..5000)) do
        path = Path.join(temp_dir, "#{System.unique_integer([:positive])}.txt")
        # Create file with more lines than any limit we'll test
        content = Enum.map_join(1..6000, "\n", &"line #{&1}")
        File.write!(path, content)

        {:ok, result} = FileRead.execute(%{path: path, limit: limit}, "agent-1", [])

        # Even though we requested > 2000, should be capped at 2000
        # Count actual lines in result content
        actual_lines = result.content |> String.split("\n") |> length()

        assert actual_lines <= 2000,
               "Requested limit #{limit} should be capped at 2000, got #{actual_lines}"

        File.rm!(path)
      end
    end
  end

  describe "R14: line number accuracy" do
    property "line numbers match content positions", %{temp_dir: temp_dir} do
      # [UNIT] - FOR ANY file content THEN line numbers match actual positions
      check all(
              lines <-
                list_of(string(:alphanumeric, min_length: 1), min_length: 1, max_length: 100)
            ) do
        path = Path.join(temp_dir, "#{System.unique_integer([:positive])}.txt")
        content = Enum.join(lines, "\n")
        File.write!(path, content)

        {:ok, result} = FileRead.execute(%{path: path}, "agent-1", [])

        # Verify line numbers are sequential and match
        output_lines = String.split(result.content, "\n", trim: true)

        Enum.each(Enum.with_index(output_lines, 1), fn {line, expected_num} ->
          [num_str | _] = String.split(line, "\t", parts: 2)
          assert String.to_integer(num_str) == expected_num
        end)

        File.rm!(path)
      end
    end
  end

  # ===========================================================================
  # R15: Router Integration - Tested in router_file_actions_test.exs
  # ===========================================================================
  # R15 [INTEGRATION] test requires Router with isolated dependencies.
  # Following existing pattern (router_web_test.exs, router_send_message_test.exs),
  # Router integration tests are in a separate file: router_file_actions_test.exs
  # This file focuses on FileRead module unit tests (R1-R14).
end
