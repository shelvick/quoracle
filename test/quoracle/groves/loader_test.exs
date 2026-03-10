defmodule Quoracle.Groves.LoaderTest do
  @moduledoc """
  Unit and integration tests for GROVE_Loader module.
  Tests grove manifest parsing, listing, bootstrap extraction, path fallback chain, and error handling
  with isolated temp directories.

  ARC Criteria: R1-R13 from GROVE_Loader spec
  Cross-Packet Note: R9 and R10 test DB config fallback (Packet 3).
  Tagged @tag :packet_3 — exclude during Packet 1 cycle.
  """
  use Quoracle.DataCase, async: true

  @moduletag :feat_grove_system

  alias Quoracle.Groves.Loader

  setup do
    # Create unique temp directory per test for isolation
    base_name = "test_groves/#{System.unique_integer([:positive])}"
    temp_dir = Path.join(System.tmp_dir!(), base_name)

    File.mkdir_p!(temp_dir)

    on_exit(fn -> File.rm_rf!(temp_dir) end)

    %{groves_path: temp_dir, base_name: base_name}
  end

  # Helper to create a mock grove with GROVE.md frontmatter.
  # Uses System.tmp_dir!() inline for git hook static analysis compatibility.
  defp create_grove(base_name, name, frontmatter) do
    grove_dir = Path.join([System.tmp_dir!(), base_name, name])
    File.mkdir_p!(grove_dir)
    grove_md = Path.join(grove_dir, "GROVE.md")

    content = """
    ---
    #{frontmatter}
    ---

    # #{name}

    Grove description body.
    """

    File.write!(grove_md, content)
    grove_dir
  end

  # Helper to create a grove with raw content (for testing malformed YAML).
  defp create_grove_raw(base_name, name, raw_content) do
    grove_dir = Path.join([System.tmp_dir!(), base_name, name])
    grove_md = Path.join([System.tmp_dir!(), base_name, name, "GROVE.md"])
    File.mkdir_p!(grove_dir)
    File.write!(grove_md, raw_content)
    grove_dir
  end

  # =============================================================================
  # R1-R4: list_groves/1
  # =============================================================================

  describe "list_groves/1" do
    @tag :r1
    test "R1: returns sorted metadata for valid groves", %{
      groves_path: path,
      base_name: base_name
    } do
      # R1: WHEN list_groves called IF groves directory has valid GROVE.md files
      # THEN returns metadata list sorted by name
      create_grove(
        base_name,
        "beta-grove",
        "name: beta-grove\ndescription: Beta\nversion: \"1.0\""
      )

      create_grove(
        base_name,
        "alpha-grove",
        "name: alpha-grove\ndescription: Alpha\nversion: \"2.0\""
      )

      assert {:ok, groves} = Loader.list_groves(groves_path: path)
      assert length(groves) == 2

      # Sorted alphabetically by name
      assert hd(groves).name == "alpha-grove"
      assert List.last(groves).name == "beta-grove"

      # Verify metadata structure
      alpha = hd(groves)
      assert alpha.name == "alpha-grove"
      assert alpha.description == "Alpha"
      assert alpha.version == "2.0"
      assert alpha.path =~ "alpha-grove"
    end

    @tag :r2
    test "R2: returns empty list for empty directory", %{groves_path: path} do
      # R2: WHEN list_groves called IF groves directory exists but empty THEN returns {:ok, []}
      assert {:ok, []} = Loader.list_groves(groves_path: path)
    end

    @tag :r3
    test "R3: returns empty list for missing directory" do
      # R3: WHEN list_groves called IF groves directory doesn't exist THEN returns {:ok, []}
      assert {:ok, []} =
               Loader.list_groves(groves_path: "/tmp/nonexistent_#{System.unique_integer()}")
    end

    @tag :r4
    test "R4: skips groves with malformed frontmatter", %{groves_path: path, base_name: base_name} do
      # R4: WHEN list_groves called IF some groves have malformed frontmatter
      # THEN returns valid groves only, skips malformed
      create_grove(
        base_name,
        "good-grove",
        "name: good-grove\ndescription: Good\nversion: \"1.0\""
      )

      # Create malformed grove (no frontmatter)
      create_grove_raw(base_name, "bad-grove", "no frontmatter here")

      assert {:ok, [grove]} = Loader.list_groves(groves_path: path)
      assert grove.name == "good-grove"
    end
  end

  # =============================================================================
  # R5-R6: load_grove/2
  # =============================================================================

  describe "load_grove/2" do
    @tag :r5
    test "R5: returns complete grove struct", %{groves_path: path, base_name: base_name} do
      # R5: WHEN load_grove called with valid name
      # THEN returns complete grove struct with bootstrap, topology, skills_path
      frontmatter = """
      name: test-grove
      description: Test
      version: "1.0"
      bootstrap:
        role: "Test Role"
        cognitive_style: analytical
        skills:
          - skill1
          - skill2
      topology:
        root: test-agent
      """

      create_grove(base_name, "test-grove", frontmatter)
      skills_dir = Path.join([System.tmp_dir!(), base_name, "test-grove", "skills"])
      File.mkdir_p!(skills_dir)

      assert {:ok, grove} = Loader.load_grove("test-grove", groves_path: path)
      assert grove.name == "test-grove"
      assert grove.description == "Test"
      assert grove.version == "1.0"
      assert grove.bootstrap.role == "Test Role"
      assert grove.bootstrap.cognitive_style == "analytical"
      assert grove.bootstrap.skills == ["skill1", "skill2"]
      assert grove.skills_path == skills_dir
    end

    @tag :r6
    test "R6: returns error for unknown grove", %{groves_path: path} do
      # R6: WHEN load_grove called with unknown name THEN returns {:error, :not_found}
      assert {:error, :not_found} = Loader.load_grove("nonexistent", groves_path: path)
    end
  end

  # =============================================================================
  # R7: get_bootstrap/2
  # =============================================================================

  describe "get_bootstrap/2" do
    @tag :r7
    test "R7: returns bootstrap section with all field types", %{
      groves_path: path,
      base_name: base_name
    } do
      # R7: WHEN get_bootstrap called THEN returns bootstrap section
      # with all field types (file refs + inline values)
      frontmatter = """
      name: full-grove
      description: Full bootstrap
      version: "1.0"
      bootstrap:
        global_context_file: bootstrap/context.md
        task_description_file: bootstrap/task.md
        role: "Senior Engineer"
        cognitive_style: analytical
        delegation_strategy: full_delegation
        output_style: structured
        skills:
          - deployment
          - testing
        profile: balanced
        budget_limit: 50.0
        global_constraints: "Must use TypeScript"
        approach_guidance_file: bootstrap/approach.md
      """

      create_grove(base_name, "full-grove", frontmatter)

      assert {:ok, bootstrap} = Loader.get_bootstrap("full-grove", groves_path: path)

      # File reference fields
      assert bootstrap.global_context_file == "bootstrap/context.md"
      assert bootstrap.task_description_file == "bootstrap/task.md"
      assert bootstrap.approach_guidance_file == "bootstrap/approach.md"

      # Inline value fields
      assert bootstrap.role == "Senior Engineer"
      assert bootstrap.cognitive_style == "analytical"
      assert bootstrap.delegation_strategy == "full_delegation"
      assert bootstrap.output_style == "structured"
      assert bootstrap.global_constraints == "Must use TypeScript"

      # Typed fields
      assert bootstrap.skills == ["deployment", "testing"]
      assert bootstrap.profile == "balanced"
      assert bootstrap.budget_limit == 50.0
    end
  end

  # =============================================================================
  # R8-R11: Groves Path Fallback Chain
  # =============================================================================

  describe "groves_path fallback" do
    @tag :r8
    test "R8: opts path takes precedence", %{groves_path: path, base_name: base_name} do
      # R8: WHEN groves_path in opts THEN uses opts path (ignores DB and default)
      create_grove(
        base_name,
        "opt-grove",
        "name: opt-grove\ndescription: Via opts\nversion: \"1.0\""
      )

      assert {:ok, [grove]} = Loader.list_groves(groves_path: path)
      assert grove.name == "opt-grove"
    end

    @tag :packet_3
    @tag :r9
    test "R9: falls back to DB config", %{groves_path: path, base_name: base_name} do
      # NOTE: Requires CONFIG_ModelSettings v6.0 (Packet 3) -- run in Packet 3 cycle
      # R9: WHEN no opts groves_path IF DB has groves_path THEN uses DB path
      create_grove(base_name, "db-grove", "name: db-grove\ndescription: Via DB\nversion: \"1.0\"")

      alias Quoracle.Models.ConfigModelSettings
      {:ok, _} = ConfigModelSettings.set_groves_path(path)
      # No on_exit needed: DataCase sandbox rolls back DB changes automatically

      assert {:ok, [grove]} = Loader.list_groves([])
      assert grove.name == "db-grove"
    end

    @tag :packet_3
    @tag :r10
    test "R10: falls back to default path when no opts and no DB config" do
      # NOTE: Requires CONFIG_ModelSettings v6.0 (Packet 3) -- tagged for Packet 3 cycle
      # R10: WHEN no opts and no DB config THEN uses ~/.quoracle/groves
      alias Quoracle.Models.ConfigModelSettings
      ConfigModelSettings.delete_groves_path()
      # No on_exit needed: DataCase sandbox rolls back DB changes automatically

      # Create a grove in a known temp path and verify the default path is NOT our temp path
      unique_id = System.unique_integer([:positive])
      temp_path = Path.join([System.tmp_dir!(), "test_default_groves", to_string(unique_id)])

      grove_dir =
        Path.join([System.tmp_dir!(), "test_default_groves", to_string(unique_id), "temp-grove"])

      grove_md =
        Path.join([
          System.tmp_dir!(),
          "test_default_groves",
          to_string(unique_id),
          "temp-grove",
          "GROVE.md"
        ])

      File.mkdir_p!(grove_dir)
      File.write!(grove_md, "---\nname: temp-grove\ndescription: Temp\nversion: \"1.0\"\n---\n")

      on_exit(fn -> File.rm_rf!(temp_path) end)

      # Without opts or DB config, falls back to ~/.quoracle/groves
      # This should NOT find our temp-grove (proving it used the default path)
      assert {:ok, groves} = Loader.list_groves([])
      assert is_list(groves)
      refute Enum.any?(groves, fn g -> g.name == "temp-grove" end)
    end

    @tag :r11
    test "R11: tilde expansion resolves to home directory", %{groves_path: _path} do
      # R11: WHEN groves_path contains ~ THEN expands to home directory
      # Strategy: create grove files under System.tmp_dir!(), then symlink from ~/unique_dir
      # so the tilde path resolves to the actual temp directory.
      home = System.user_home!()
      unique_id = System.unique_integer([:positive])
      symlink_name = "test_tilde_groves_#{unique_id}"
      symlink_path = Path.join(home, symlink_name)
      tilde_path = "~/#{symlink_name}"

      # Create actual grove directory inside System.tmp_dir!()
      actual_groves_dir = Path.join(System.tmp_dir!(), "tilde_target_groves_#{unique_id}")
      grove_dir = Path.join(System.tmp_dir!(), "tilde_target_groves_#{unique_id}/tilde-grove")

      grove_md =
        Path.join(System.tmp_dir!(), "tilde_target_groves_#{unique_id}/tilde-grove/GROVE.md")

      grove_content = "---\nname: tilde-grove\ndescription: Tilde test\nversion: \"1.0\"\n---\n"
      File.mkdir_p!(grove_dir)
      File.write!(grove_md, grove_content)

      # Create symlink from ~/unique_dir -> actual temp dir
      File.ln_s!(actual_groves_dir, symlink_path)

      on_exit(fn ->
        File.rm(symlink_path)
        File.rm_rf!(actual_groves_dir)
      end)

      # Pass tilde path -- should expand ~ to home, follow symlink to temp dir
      assert {:ok, [grove]} = Loader.list_groves(groves_path: tilde_path)
      assert grove.name == "tilde-grove"
    end
  end

  # =============================================================================
  # R12-R13: Skills Path
  # =============================================================================

  describe "grove skills_path" do
    @tag :r12
    test "R12: computed when skills/ exists", %{groves_path: path, base_name: base_name} do
      # R12: WHEN grove has skills/ subdirectory THEN grove.skills_path set to that path
      create_grove(
        base_name,
        "skilled-grove",
        "name: skilled-grove\ndescription: Has skills\nversion: \"1.0\""
      )

      skills_dir = Path.join([System.tmp_dir!(), base_name, "skilled-grove", "skills"])
      File.mkdir_p!(skills_dir)

      assert {:ok, grove} = Loader.load_grove("skilled-grove", groves_path: path)
      assert grove.skills_path == skills_dir
    end

    @tag :r13
    test "R13: nil when no skills/ directory", %{groves_path: path, base_name: base_name} do
      # R13: WHEN grove has no skills/ subdirectory THEN grove.skills_path is nil
      create_grove(
        base_name,
        "no-skills-grove",
        "name: no-skills-grove\ndescription: No skills\nversion: \"1.0\""
      )

      assert {:ok, grove} = Loader.load_grove("no-skills-grove", groves_path: path)
      assert is_nil(grove.skills_path)
    end
  end

  # =============================================================================
  # Edge Cases and Error Handling
  # =============================================================================

  describe "edge cases" do
    test "handles grove directory without GROVE.md file", %{
      groves_path: path,
      base_name: base_name
    } do
      # Directory exists but no GROVE.md file
      File.mkdir_p!(Path.join([System.tmp_dir!(), base_name, "empty-grove"]))

      # Should not appear in list (no valid GROVE.md)
      {:ok, groves} = Loader.list_groves(groves_path: path)
      refute Enum.any?(groves, &(&1.name == "empty-grove"))

      # load_grove should return not_found
      assert {:error, :not_found} = Loader.load_grove("empty-grove", groves_path: path)
    end

    test "handles empty GROVE.md file", %{groves_path: path, base_name: base_name} do
      create_grove_raw(base_name, "empty-file", "")

      assert {:error, _reason} = Loader.load_grove("empty-file", groves_path: path)
    end

    test "load_grove returns parse_error for malformed YAML", %{
      groves_path: path,
      base_name: base_name
    } do
      content = """
      ---
      name: [invalid yaml without closing bracket
      description: this won't parse
      ---

      Content
      """

      create_grove_raw(base_name, "bad-yaml-grove", content)

      assert {:error, :parse_error} = Loader.load_grove("bad-yaml-grove", groves_path: path)
    end

    test "ignores non-directory files in groves directory", %{
      groves_path: path,
      base_name: base_name
    } do
      # Create a regular file in groves directory (not a grove directory)
      File.write!(Path.join([System.tmp_dir!(), base_name, "not-a-grove.txt"]), "just a file")

      create_grove(
        base_name,
        "real-grove",
        "name: real-grove\ndescription: Real\nversion: \"1.0\""
      )

      {:ok, groves} = Loader.list_groves(groves_path: path)

      assert length(groves) == 1
      assert hd(groves).name == "real-grove"
    end

    test "get_bootstrap returns error for nonexistent grove", %{groves_path: path} do
      assert {:error, :not_found} = Loader.get_bootstrap("nonexistent", groves_path: path)
    end

    test "grove without bootstrap section has nil bootstrap fields", %{
      groves_path: path,
      base_name: base_name
    } do
      # A grove with no bootstrap section at all should still load
      create_grove(
        base_name,
        "no-bootstrap",
        "name: no-bootstrap\ndescription: No bootstrap\nversion: \"1.0\""
      )

      assert {:ok, grove} = Loader.load_grove("no-bootstrap", groves_path: path)
      assert grove.name == "no-bootstrap"

      # Bootstrap should exist but with nil fields
      assert {:ok, bootstrap} = Loader.get_bootstrap("no-bootstrap", groves_path: path)
      assert is_nil(bootstrap.global_context_file)
      assert is_nil(bootstrap.role)
      assert is_nil(bootstrap.skills)
    end
  end

  # =============================================================================
  # SEC-1: Path Traversal Protection in Loader
  # =============================================================================

  describe "path traversal protection" do
    @tag :sec1
    test "SEC-1e: sanitizes file refs with .. traversal", %{
      groves_path: path,
      base_name: base_name
    } do
      # SEC-1e: WHEN GROVE.md frontmatter has bootstrap file refs with ".." path components
      # THEN get_bootstrap either strips them or returns error (prevents directory escape)
      # The Loader builds bootstrap map from raw frontmatter - file refs with ".."
      # should be rejected at this level before BootstrapResolver ever sees them.
      frontmatter = """
      name: traversal-grove
      description: Malicious grove
      version: "1.0"
      bootstrap:
        global_context_file: ../../../etc/passwd
        task_description_file: subdir/../../secret.txt
      """

      create_grove(base_name, "traversal-grove", frontmatter)

      result = Loader.get_bootstrap("traversal-grove", groves_path: path)

      # If result is {:ok, bootstrap}, paths must NOT contain ".."
      # If result is {:error, _}, that's also acceptable (rejection)
      case result do
        {:ok, bootstrap} ->
          if bootstrap.global_context_file do
            refute String.contains?(bootstrap.global_context_file, ".."),
                   "File ref should not contain '..' traversal: #{bootstrap.global_context_file}"
          end

          if bootstrap.task_description_file do
            refute String.contains?(bootstrap.task_description_file, ".."),
                   "File ref should not contain '..' traversal: #{bootstrap.task_description_file}"
          end

        {:error, _} ->
          # Rejection is acceptable
          assert true
      end
    end

    @tag :sec1
    test "SEC-1f: build_bootstrap sanitizes absolute file refs", %{
      groves_path: path,
      base_name: base_name
    } do
      # SEC-1f: WHEN GROVE.md frontmatter has bootstrap file refs with absolute paths
      # THEN get_bootstrap either strips them or returns error
      frontmatter = """
      name: abs-path-grove
      description: Malicious grove with absolute paths
      version: "1.0"
      bootstrap:
        global_context_file: /etc/shadow
      """

      create_grove(base_name, "abs-path-grove", frontmatter)

      result = Loader.get_bootstrap("abs-path-grove", groves_path: path)

      case result do
        {:ok, bootstrap} ->
          if bootstrap.global_context_file do
            refute String.starts_with?(bootstrap.global_context_file, "/"),
                   "File ref should not be absolute: #{bootstrap.global_context_file}"
          end

        {:error, _} ->
          # Rejection is acceptable
          assert true
      end
    end
  end

  # =============================================================================
  # R19-R21: Schema Definition Sanitization and Workspace Parsing (v4.0)
  # WorkGroupID: wip-20260301-grove-schema-validation
  # =============================================================================

  describe "schema definition sanitization (R19)" do
    @tag :r19
    test "R19: Loader sanitizes schema definition paths at parse time", %{
      groves_path: path,
      base_name: base_name
    } do
      # R19: WHEN GROVE.md has schema entry with `../` in definition path
      # THEN Loader sanitizes the path before storing in grove struct (defense layer 1)
      frontmatter = """
      name: schema-sanitize-grove
      description: Schema sanitization test
      version: "1.0"
      schemas:
        - name: output-schema
          definition: ../../../etc/passwd
          validate_on: file_write
          path_pattern: "**/*.json"
        - name: clean-schema
          definition: schemas/clean.json
          validate_on: file_write
          path_pattern: "**/*.yaml"
      """

      create_grove(base_name, "schema-sanitize-grove", frontmatter)

      assert {:ok, grove} = Loader.load_grove("schema-sanitize-grove", groves_path: path)

      assert is_list(grove.schemas), "grove.schemas must be a list"
      assert length(grove.schemas) == 2

      traversal_schema = Enum.find(grove.schemas, &(&1["name"] == "output-schema"))
      assert traversal_schema, "schema named 'output-schema' must be present"

      # Sanitized definition must not contain '..' traversal
      definition = Map.get(traversal_schema, "definition")

      if definition do
        refute String.contains?(definition, ".."),
               "Schema definition path must not contain '..' after sanitization, got: #{inspect(definition)}"

        refute String.starts_with?(definition, "/"),
               "Schema definition path must not be absolute after sanitization, got: #{inspect(definition)}"
      end

      # Clean schema definition must be preserved
      clean_schema = Enum.find(grove.schemas, &(&1["name"] == "clean-schema"))
      assert clean_schema, "schema named 'clean-schema' must be present"
      assert Map.get(clean_schema, "definition") == "schemas/clean.json"
    end

    @tag :r19b
    test "R19b: Loader sanitizes absolute definition paths", %{
      groves_path: path,
      base_name: base_name
    } do
      # WHEN schema definition uses absolute path THEN it is stripped of leading /
      frontmatter = """
      name: schema-abs-grove
      description: Absolute path sanitization
      version: "1.0"
      schemas:
        - name: abs-schema
          definition: /etc/shadow
          validate_on: file_write
          path_pattern: "**/*.txt"
      """

      create_grove(base_name, "schema-abs-grove", frontmatter)

      assert {:ok, grove} = Loader.load_grove("schema-abs-grove", groves_path: path)

      assert is_list(grove.schemas)
      [schema] = grove.schemas
      definition = Map.get(schema, "definition")

      if definition do
        refute String.starts_with?(definition, "/"),
               "Definition must not be absolute after sanitization, got: #{inspect(definition)}"
      end
    end
  end

  describe "workspace field parsing (R20-R21)" do
    @tag :r20
    test "R20: Loader parses and expands workspace from frontmatter", %{
      groves_path: path,
      base_name: base_name
    } do
      # R20: WHEN GROVE.md has `workspace: "~/venture_factory"` THEN
      # grove struct has workspace as expanded absolute path
      frontmatter = """
      name: workspace-grove
      description: Workspace test
      version: "1.0"
      workspace: ~/test_workspace_#{System.unique_integer([:positive])}
      """

      create_grove(base_name, "workspace-grove", frontmatter)

      assert {:ok, grove} = Loader.load_grove("workspace-grove", groves_path: path)

      assert Map.has_key?(grove, :workspace),
             "grove struct must have :workspace field"

      assert is_binary(grove.workspace),
             "workspace must be a string (expanded path)"

      # Must be expanded (not start with ~)
      refute String.starts_with?(grove.workspace, "~"),
             "workspace must be expanded, not tilde: #{inspect(grove.workspace)}"

      # Must be absolute (starts with /)
      assert String.starts_with?(grove.workspace, "/"),
             "workspace must be absolute path: #{inspect(grove.workspace)}"

      # Must contain the path component (expanded from ~)
      assert grove.workspace =~ "test_workspace_"
    end

    @tag :r20b
    test "R20b: Loader expands absolute workspace path unchanged", %{
      groves_path: path,
      base_name: base_name
    } do
      # WHEN workspace is already absolute THEN Path.expand returns it unchanged
      unique = System.unique_integer([:positive])

      frontmatter = """
      name: abs-workspace-grove
      description: Absolute workspace test
      version: "1.0"
      workspace: /tmp/test_abs_workspace_#{unique}
      """

      create_grove(base_name, "abs-workspace-grove", frontmatter)

      assert {:ok, grove} = Loader.load_grove("abs-workspace-grove", groves_path: path)

      assert is_binary(grove.workspace)
      assert grove.workspace =~ "test_abs_workspace_#{unique}"
    end

    @tag :r21
    test "R21: Loader sets workspace to nil when not in frontmatter", %{
      groves_path: path,
      base_name: base_name
    } do
      # R21: WHEN GROVE.md has no workspace field THEN grove.workspace is nil
      frontmatter = """
      name: no-workspace-grove
      description: No workspace
      version: "1.0"
      bootstrap:
        role: "Test Agent"
      """

      create_grove(base_name, "no-workspace-grove", frontmatter)

      assert {:ok, grove} = Loader.load_grove("no-workspace-grove", groves_path: path)

      assert Map.has_key?(grove, :workspace),
             "grove struct must have :workspace field even when absent in frontmatter"

      assert is_nil(grove.workspace),
             "workspace must be nil when not present in frontmatter, got: #{inspect(grove.workspace)}"
    end
  end

  # =============================================================================
  # R22-R26: Confinement and typed hard_rules parsing (v5.0)
  # WorkGroupID: wip-20260302-grove-hard-enforcement
  # =============================================================================

  describe "confinement parsing (R22-R24)" do
    @tag :r22
    test "R22: Loader parses confinement section from frontmatter", %{
      groves_path: path,
      base_name: base_name
    } do
      frontmatter = """
      name: confinement-grove
      description: Confinement parse test
      version: "1.0"
      confinement:
        venture-management:
          paths:
            - ~/venture_factory/ventures/**
          read_only_paths:
            - ~/venture_factory/shared/**
      """

      create_grove(base_name, "confinement-grove", frontmatter)

      assert {:ok, grove} = Loader.load_grove("confinement-grove", groves_path: path)
      assert Map.has_key?(grove, :confinement)
      assert is_map(grove.confinement)

      assert %{"paths" => paths, "read_only_paths" => read_only_paths} =
               grove.confinement["venture-management"]

      assert is_list(paths)
      assert is_list(read_only_paths)
    end

    @tag :r23
    test "R23: Loader expands tilde in confinement paths", %{
      groves_path: path,
      base_name: base_name
    } do
      frontmatter = """
      name: confinement-expand-grove
      description: Confinement expansion test
      version: "1.0"
      confinement:
        venture-management:
          paths:
            - ~/venture_factory/ventures/**
          read_only_paths:
            - ~/venture_factory/shared/**
      """

      create_grove(base_name, "confinement-expand-grove", frontmatter)

      assert {:ok, grove} = Loader.load_grove("confinement-expand-grove", groves_path: path)
      conf = grove.confinement["venture-management"]

      assert Enum.all?(conf["paths"], &String.starts_with?(&1, "/"))
      assert Enum.all?(conf["read_only_paths"], &String.starts_with?(&1, "/"))
      refute Enum.any?(conf["paths"], &String.starts_with?(&1, "~"))
      refute Enum.any?(conf["read_only_paths"], &String.starts_with?(&1, "~"))
    end

    @tag :r24
    test "R24: Loader sets confinement to nil when not in frontmatter", %{
      groves_path: path,
      base_name: base_name
    } do
      frontmatter = """
      name: no-confinement-grove
      description: No confinement field
      version: "1.0"
      """

      create_grove(base_name, "no-confinement-grove", frontmatter)

      assert {:ok, grove} = Loader.load_grove("no-confinement-grove", groves_path: path)
      assert Map.has_key?(grove, :confinement)
      assert is_nil(grove.confinement)
    end
  end

  describe "typed hard_rules parsing (R25-R26)" do
    @tag :r25
    test "R25: Loader validates hard_rules entries for required fields", %{
      groves_path: path,
      base_name: base_name
    } do
      frontmatter = """
      name: hard-rules-valid-grove
      description: Hard rules validation test
      version: "1.0"
      governance:
        hard_rules:
          - type: shell_pattern_block
            pattern: pkill|killall
            message: Never mass-kill processes
      """

      create_grove(base_name, "hard-rules-valid-grove", frontmatter)

      assert {:ok, grove} = Loader.load_grove("hard-rules-valid-grove", groves_path: path)
      assert %{"hard_rules" => [rule]} = grove.governance
      assert rule["type"] == "shell_pattern_block"
      assert rule["pattern"] == "pkill|killall"
      assert rule["message"] == "Never mass-kill processes"
      assert rule["scope"] == "all"
    end

    @tag :r26
    test "R26: Loader filters invalid hard_rule entries", %{
      groves_path: path,
      base_name: base_name
    } do
      frontmatter = """
      name: hard-rules-filter-grove
      description: Hard rules filtering test
      version: "1.0"
      governance:
        hard_rules:
          - type: shell_pattern_block
            pattern: pkill|killall
            message: valid
          - type: shell_pattern_block
            pattern: rm -rf /
          - type: shell_pattern_block
            message: missing pattern
          - pattern: pgrep
            message: missing type
      """

      create_grove(base_name, "hard-rules-filter-grove", frontmatter)

      assert {:ok, grove} = Loader.load_grove("hard-rules-filter-grove", groves_path: path)
      assert %{"hard_rules" => rules} = grove.governance
      assert length(rules) == 1

      [rule] = rules
      assert rule["type"] == "shell_pattern_block"
      assert rule["pattern"] == "pkill|killall"
      assert rule["message"] == "valid"
    end
  end

  describe "hard_rules action_block parsing (R27-R30)" do
    @tag :r27
    test "R27: Loader preserves action_block hard rule entries", %{
      groves_path: path,
      base_name: base_name
    } do
      frontmatter = """
      name: block-grove
      description: Block grove
      version: "1.0"
      governance:
        hard_rules:
          - type: action_block
            actions:
              - answer_engine
              - fetch_web
            message: "Benchmark grove: external queries not permitted."
            scope: all
      """

      create_grove(base_name, "block-grove", frontmatter)

      assert {:ok, grove} = Loader.load_grove("block-grove", groves_path: path)
      assert [rule] = grove.governance["hard_rules"]
      assert rule["type"] == "action_block"
      assert rule["actions"] == ["answer_engine", "fetch_web"]
      assert rule["message"] =~ "Benchmark grove"
      assert rule["scope"] == "all"
    end

    @tag :r28
    test "R28: Loader filters action_block entries missing actions field", %{
      groves_path: path,
      base_name: base_name
    } do
      frontmatter = """
      name: bad-block-grove
      description: Bad block grove
      version: "1.0"
      governance:
        hard_rules:
          - type: action_block
            message: "Missing actions field"
            scope: all
      """

      create_grove(base_name, "bad-block-grove", frontmatter)

      assert {:ok, grove} = Loader.load_grove("bad-block-grove", groves_path: path)
      assert grove.governance["hard_rules"] == []
    end

    @tag :r29
    test "R29: Loader filters action_block entries with non-list actions", %{
      groves_path: path,
      base_name: base_name
    } do
      frontmatter = """
      name: string-actions-grove
      description: String actions grove
      version: "1.0"
      governance:
        hard_rules:
          - type: action_block
            actions: answer_engine
            message: "Actions should be a list"
            scope: all
      """

      create_grove(base_name, "string-actions-grove", frontmatter)

      assert {:ok, grove} = Loader.load_grove("string-actions-grove", groves_path: path)
      assert grove.governance["hard_rules"] == []
    end

    @tag :r30
    test "R30: Loader preserves mixed shell_pattern_block and action_block rules", %{
      groves_path: path,
      base_name: base_name
    } do
      frontmatter = """
      name: mixed-grove
      description: Mixed rules grove
      version: "1.0"
      governance:
        hard_rules:
          - type: shell_pattern_block
            pattern: pkill
            message: "No pkill"
            scope: all
          - type: action_block
            actions:
              - answer_engine
            message: "No answer engine"
            scope: all
      """

      create_grove(base_name, "mixed-grove", frontmatter)

      assert {:ok, grove} = Loader.load_grove("mixed-grove", groves_path: path)
      assert length(grove.governance["hard_rules"]) == 2
      types = Enum.map(grove.governance["hard_rules"], & &1["type"])
      assert "shell_pattern_block" in types
      assert "action_block" in types
    end
  end

  # =============================================================================
  # SEC-4: File.read! Crash Protection
  # =============================================================================

  describe "GROVE.md read error handling" do
    @tag :sec4
    test "SEC-4a: load_grove handles unreadable GROVE.md", %{
      groves_path: path,
      base_name: base_name
    } do
      # SEC-4a: WHEN GROVE.md exists but is unreadable (permission denied)
      # THEN load_grove returns {:error, _} instead of crashing with File.read!
      grove_dir = Path.join([System.tmp_dir!(), base_name, "unreadable-grove"])
      grove_md = Path.join(grove_dir, "GROVE.md")
      File.mkdir_p!(grove_dir)
      File.write!(grove_md, "---\nname: unreadable\n---\n")
      # Remove read permission
      File.chmod!(grove_md, 0o000)

      on_exit(fn ->
        # Restore permissions so cleanup can remove the file
        File.chmod(grove_md, 0o644)
      end)

      # Should return error tuple, not crash
      assert {:error, _reason} = Loader.load_grove("unreadable-grove", groves_path: path)
    end

    @tag :sec4
    test "SEC-4b: list_groves skips unreadable GROVE.md", %{
      groves_path: path,
      base_name: base_name
    } do
      # SEC-4b: WHEN listing groves and one has unreadable GROVE.md
      # THEN list_groves skips it gracefully instead of crashing
      # Create a good grove
      create_grove(
        base_name,
        "good-grove",
        "name: good-grove\ndescription: Good\nversion: \"1.0\""
      )

      # Create a grove with unreadable GROVE.md
      bad_dir = Path.join([System.tmp_dir!(), base_name, "bad-perms-grove"])
      bad_md = Path.join(bad_dir, "GROVE.md")
      File.mkdir_p!(bad_dir)
      File.write!(bad_md, "---\nname: bad-perms\n---\n")
      File.chmod!(bad_md, 0o000)

      on_exit(fn -> File.chmod(bad_md, 0o644) end)

      # Should return the good grove, skip the bad one (no crash)
      assert {:ok, groves} = Loader.list_groves(groves_path: path)
      assert length(groves) == 1
      assert hd(groves).name == "good-grove"
    end
  end
end
