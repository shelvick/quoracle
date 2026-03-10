defmodule Quoracle.Groves.BootstrapResolverTest do
  @moduledoc """
  Unit and integration tests for GROVE_BootstrapResolver module.
  Tests file reference resolution, inline value pass-through, formatting,
  error handling, and full resolution pipeline.

  ARC Criteria: R1-R11 from GROVE_BootstrapResolver spec
  """
  use ExUnit.Case, async: true

  @moduletag :feat_grove_system

  alias Quoracle.Groves.BootstrapResolver

  setup do
    # Create unique temp directory per test for isolation
    base_name = "test_bootstrap_groves/#{System.unique_integer([:positive])}"
    temp_dir = Path.join(System.tmp_dir!(), base_name)

    File.mkdir_p!(temp_dir)

    on_exit(fn -> File.rm_rf!(temp_dir) end)

    %{groves_path: temp_dir, base_name: base_name}
  end

  # Helper to create a grove with bootstrap config and optional files.
  # Uses System.tmp_dir!() inline in every File.* call for git hook static analysis compatibility.
  defp create_bootstrap_grove(base_name, name, opts) do
    File.mkdir_p!(Path.join([System.tmp_dir!(), base_name, name]))

    # Write bootstrap files if provided
    files = Keyword.get(opts, :files, %{})

    for {filename, content} <- files do
      File.mkdir_p!(Path.join([System.tmp_dir!(), base_name, name, Path.dirname(filename)]))
      File.write!(Path.join([System.tmp_dir!(), base_name, name, filename]), content)
    end

    # Write GROVE.md with frontmatter including bootstrap section
    bootstrap_yaml = Keyword.get(opts, :bootstrap_yaml, "")

    grove_md_content = """
    ---
    name: #{name}
    description: Test grove
    version: "1.0"
    bootstrap:
    #{bootstrap_yaml}
    ---

    # #{name}

    Grove description body.
    """

    File.write!(Path.join([System.tmp_dir!(), base_name, name, "GROVE.md"]), grove_md_content)
    Path.join([System.tmp_dir!(), base_name, name])
  end

  # =============================================================================
  # R1, R10: File Reference Resolution
  # =============================================================================

  describe "file reference resolution" do
    @tag :r1
    test "R1: resolves file reference fields to content", %{
      groves_path: path,
      base_name: base_name
    } do
      # R1: WHEN bootstrap has global_context_file THEN reads file content
      # and maps to :global_context
      create_bootstrap_grove(base_name, "file-grove",
        bootstrap_yaml: "  global_context_file: bootstrap/context.md",
        files: %{"bootstrap/context.md" => "Global context content here"}
      )

      assert {:ok, fields} = BootstrapResolver.resolve("file-grove", groves_path: path)
      assert fields.global_context == "Global context content here"
    end

    @tag :r10
    test "R10: all four file reference fields resolved", %{
      groves_path: path,
      base_name: base_name
    } do
      # R10: WHEN bootstrap has all 4 file refs THEN all 4 resolved to content
      create_bootstrap_grove(base_name, "all-files-grove",
        bootstrap_yaml: """
          global_context_file: bootstrap/context.md
          task_description_file: bootstrap/task.md
          success_criteria_file: bootstrap/criteria.md
          immediate_context_file: bootstrap/immediate.md
        """,
        files: %{
          "bootstrap/context.md" => "Context",
          "bootstrap/task.md" => "Task desc",
          "bootstrap/criteria.md" => "Criteria",
          "bootstrap/immediate.md" => "Immediate"
        }
      )

      assert {:ok, fields} = BootstrapResolver.resolve("all-files-grove", groves_path: path)
      assert fields.global_context == "Context"
      assert fields.task_description == "Task desc"
      assert fields.success_criteria == "Criteria"
      assert fields.immediate_context == "Immediate"
    end
  end

  # =============================================================================
  # R2, R7, R11: Inline Value Resolution
  # =============================================================================

  describe "inline value resolution" do
    @tag :r2
    test "R2: resolves inline value fields directly", %{
      groves_path: path,
      base_name: base_name
    } do
      # R2: WHEN bootstrap has inline keys (role, global_constraints, etc.)
      # THEN maps directly to form fields
      create_bootstrap_grove(base_name, "inline-grove",
        bootstrap_yaml: """
          role: "Senior Engineer"
          global_constraints: "Must use TypeScript"
        """
      )

      assert {:ok, fields} = BootstrapResolver.resolve("inline-grove", groves_path: path)
      assert fields.role == "Senior Engineer"
      assert fields.global_constraints == "Must use TypeScript"
    end

    @tag :r7
    test "R7: profile name passed through as string", %{
      groves_path: path,
      base_name: base_name
    } do
      # R7: WHEN bootstrap.profile is "balanced" THEN form field is "balanced"
      create_bootstrap_grove(base_name, "profile-grove", bootstrap_yaml: "  profile: balanced")

      assert {:ok, fields} = BootstrapResolver.resolve("profile-grove", groves_path: path)
      assert fields.profile == "balanced"
    end

    @tag :r11
    test "R11: enum field values passed through unchanged", %{
      groves_path: path,
      base_name: base_name
    } do
      # R11: WHEN bootstrap has cognitive_style/output_style/delegation_strategy
      # THEN values pass through unchanged
      create_bootstrap_grove(base_name, "enum-grove",
        bootstrap_yaml: """
          cognitive_style: analytical
          output_style: structured
          delegation_strategy: full_delegation
        """
      )

      assert {:ok, fields} = BootstrapResolver.resolve("enum-grove", groves_path: path)
      assert fields.cognitive_style == "analytical"
      assert fields.output_style == "structured"
      assert fields.delegation_strategy == "full_delegation"
    end
  end

  # =============================================================================
  # R3: Missing Fields
  # =============================================================================

  describe "missing fields" do
    @tag :r3
    test "R3: missing bootstrap keys produce nil form fields", %{
      groves_path: path,
      base_name: base_name
    } do
      # R3: WHEN bootstrap key absent THEN corresponding form field is nil
      create_bootstrap_grove(base_name, "minimal-grove", bootstrap_yaml: "  role: \"Only role\"")

      assert {:ok, fields} = BootstrapResolver.resolve("minimal-grove", groves_path: path)
      assert fields.role == "Only role"
      assert is_nil(fields.global_context)
      assert is_nil(fields.task_description)
      assert is_nil(fields.success_criteria)
      assert is_nil(fields.immediate_context)
      assert is_nil(fields.skills)
      assert is_nil(fields.budget_limit)
      assert is_nil(fields.cognitive_style)
      assert is_nil(fields.output_style)
      assert is_nil(fields.delegation_strategy)
      assert is_nil(fields.global_constraints)
      assert is_nil(fields.approach_guidance)
      assert is_nil(fields.profile)
    end
  end

  # =============================================================================
  # R4, R9: Error Cases
  # =============================================================================

  describe "error handling" do
    @tag :r4
    test "R4: missing file reference returns error with path", %{
      groves_path: path,
      base_name: base_name
    } do
      # R4: WHEN file reference points to missing file
      # THEN returns {:error, {:file_not_found, path}}
      create_bootstrap_grove(base_name, "bad-file-grove",
        bootstrap_yaml: "  global_context_file: bootstrap/missing.md"
      )

      assert {:error, {:file_not_found, full_path}} =
               BootstrapResolver.resolve("bad-file-grove", groves_path: path)

      assert full_path =~ "bootstrap/missing.md"
    end

    @tag :r9
    test "R9: returns error for unknown grove", %{groves_path: path} do
      # R9: WHEN resolve called with unknown grove THEN returns {:error, :grove_not_found}
      assert {:error, :grove_not_found} =
               BootstrapResolver.resolve("nonexistent", groves_path: path)
    end
  end

  # =============================================================================
  # R5, R6: Field Formatting
  # =============================================================================

  describe "field formatting" do
    @tag :r5
    test "R5: skills list formatted as comma-separated string", %{
      groves_path: path,
      base_name: base_name
    } do
      # R5: WHEN bootstrap.skills is ["a", "b", "c"] THEN form field is "a, b, c"
      create_bootstrap_grove(base_name, "skills-grove",
        bootstrap_yaml: """
          skills:
            - deployment
            - code-review
            - testing
        """
      )

      assert {:ok, fields} = BootstrapResolver.resolve("skills-grove", groves_path: path)
      assert fields.skills == "deployment, code-review, testing"
    end

    @tag :r6
    test "R6: budget number converted to string", %{
      groves_path: path,
      base_name: base_name
    } do
      # R6: WHEN bootstrap.budget_limit is 100.0 THEN form field is "100.0"
      create_bootstrap_grove(base_name, "budget-grove", bootstrap_yaml: "  budget_limit: 100.0")

      assert {:ok, fields} = BootstrapResolver.resolve("budget-grove", groves_path: path)
      assert fields.budget_limit == "100.0"
    end
  end

  # =============================================================================
  # R8: Full Integration
  # =============================================================================

  describe "full resolution" do
    @tag :r8
    test "R8: full resolve returns all fields from grove manifest", %{
      groves_path: path,
      base_name: base_name
    } do
      # R8: WHEN resolve called with valid grove name
      # THEN returns complete form_fields map with all resolved values
      create_bootstrap_grove(base_name, "full-grove",
        bootstrap_yaml: """
          global_context_file: bootstrap/context.md
          task_description_file: bootstrap/task.md
          success_criteria_file: bootstrap/criteria.md
          immediate_context_file: bootstrap/immediate.md
          approach_guidance_file: bootstrap/approach.md
          global_constraints: "Use Elixir"
          output_style: structured
          role: "Senior Engineer"
          cognitive_style: analytical
          delegation_strategy: full_delegation
          skills:
            - deployment
            - testing
          profile: balanced
          budget_limit: 250.0
        """,
        files: %{
          "bootstrap/context.md" => "Project context",
          "bootstrap/task.md" => "Build a REST API",
          "bootstrap/criteria.md" => "All tests pass",
          "bootstrap/immediate.md" => "Sprint 3 deadline",
          "bootstrap/approach.md" => "TDD first"
        }
      )

      assert {:ok, fields} = BootstrapResolver.resolve("full-grove", groves_path: path)

      # File references resolved to content
      assert fields.global_context == "Project context"
      assert fields.task_description == "Build a REST API"
      assert fields.success_criteria == "All tests pass"
      assert fields.immediate_context == "Sprint 3 deadline"

      # File references resolved to content
      assert fields.approach_guidance == "TDD first"

      # Inline values passed through
      assert fields.global_constraints == "Use Elixir"
      assert fields.output_style == "structured"
      assert fields.role == "Senior Engineer"
      assert fields.cognitive_style == "analytical"
      assert fields.delegation_strategy == "full_delegation"

      # Formatted values
      assert fields.skills == "deployment, testing"
      assert fields.profile == "balanced"
      assert fields.budget_limit == "250.0"
    end
  end

  # =============================================================================
  # SEC-1: Path Traversal Protection
  # =============================================================================

  describe "path traversal protection" do
    @tag :sec1
    test "SEC-1a: rejects file ref with .. traversal", %{
      groves_path: path,
      base_name: base_name
    } do
      # SEC-1a: WHEN bootstrap file ref contains ".." path component
      # THEN resolve returns an error (traversal prevented at Loader or Resolver level)
      # Two-layer defense: Loader.get_safe_file_ref strips ".." at parse time,
      # BootstrapResolver.path_traversal? catches any that slip through.

      # Create a file OUTSIDE the grove directory that an attacker would want to read
      File.write!(Path.join([System.tmp_dir!(), base_name, "secret.txt"]), "sensitive data")

      create_bootstrap_grove(base_name, "traversal-grove",
        bootstrap_yaml: "  global_context_file: ../secret.txt"
      )

      result = BootstrapResolver.resolve("traversal-grove", groves_path: path)
      assert {:error, _reason} = result
    end

    @tag :sec1
    test "SEC-1b: rejects file reference with absolute path", %{
      groves_path: path,
      base_name: base_name
    } do
      # SEC-1b: WHEN bootstrap file ref is an absolute path (starts with /)
      # THEN resolve returns an error (Loader strips leading / at parse time,
      # BootstrapResolver catches any that slip through)
      create_bootstrap_grove(base_name, "absolute-grove",
        bootstrap_yaml: "  global_context_file: /etc/passwd"
      )

      result = BootstrapResolver.resolve("absolute-grove", groves_path: path)
      assert {:error, _reason} = result
    end

    @tag :sec1
    test "SEC-1c: rejects nested traversal paths", %{
      groves_path: path,
      base_name: base_name
    } do
      # SEC-1c: WHEN bootstrap file ref contains nested traversal (e.g. "subdir/../../secret")
      # THEN resolve returns an error (Loader strips ".." at parse time,
      # BootstrapResolver catches any that slip through)
      create_bootstrap_grove(base_name, "nested-traversal-grove",
        bootstrap_yaml: "  task_description_file: subdir/../../secret.txt"
      )

      result = BootstrapResolver.resolve("nested-traversal-grove", groves_path: path)
      assert {:error, _reason} = result
    end

    @tag :sec1
    test "SEC-1d: allows legitimate subdirectory file references", %{
      groves_path: path,
      base_name: base_name
    } do
      # SEC-1d: WHEN bootstrap file ref is a normal relative path within the grove
      # THEN resolve succeeds (no false positives from traversal check)
      create_bootstrap_grove(base_name, "safe-grove",
        bootstrap_yaml: "  global_context_file: bootstrap/deeply/nested/context.md",
        files: %{"bootstrap/deeply/nested/context.md" => "Safe content"}
      )

      assert {:ok, fields} = BootstrapResolver.resolve("safe-grove", groves_path: path)
      assert fields.global_context == "Safe content"
    end

    @tag :sec1
    test "SEC-1g: rejects symlink pointing outside grove directory", %{
      groves_path: path,
      base_name: base_name
    } do
      # SEC-1g: WHEN a bootstrap file reference resolves to a symlink that points
      # outside the grove directory THEN resolve returns an error (not the target
      # file's contents). Defense-in-depth: grove manifests are implicitly trusted
      # but may come from shared/downloaded sources. Symlinks could be used to
      # exfiltrate files outside the grove boundary.

      # Create a sensitive file OUTSIDE the grove directory
      # Uses System.tmp_dir!() inline in every File.* call for git hook static analysis
      File.mkdir_p!(Path.join([System.tmp_dir!(), base_name, "outside_grove"]))

      secret_file = Path.join([System.tmp_dir!(), base_name, "outside_grove", "secret.txt"])
      File.write!(secret_file, "sensitive credentials here")

      # Create the grove directory structure
      File.mkdir_p!(Path.join([System.tmp_dir!(), base_name, "symlink-grove", "bootstrap"]))

      # Create a symlink INSIDE the grove's bootstrap dir pointing to the secret file
      symlink_target =
        Path.join([System.tmp_dir!(), base_name, "symlink-grove", "bootstrap", "context.md"])

      File.ln_s!(secret_file, symlink_target)

      # Write GROVE.md referencing the symlink (which looks like a normal file ref)
      grove_md = Path.join([System.tmp_dir!(), base_name, "symlink-grove", "GROVE.md"])

      File.write!(grove_md, """
      ---
      name: symlink-grove
      description: Grove with symlink attack
      version: "1.0"
      bootstrap:
        global_context_file: bootstrap/context.md
      ---

      # symlink-grove

      Grove description body.
      """)

      # The resolve MUST reject the symlink rather than following it
      result = BootstrapResolver.resolve("symlink-grove", groves_path: path)

      # Must be an error - symlink should NOT be followed
      assert {:error, {:symlink_not_allowed, "bootstrap/context.md"}} = result
    end

    @tag :sec1
    test "SEC-1h: rejects symlinked intermediate directory outside grove", %{
      groves_path: path,
      base_name: base_name
    } do
      # SEC-1h: WHEN an intermediate directory component in the file path is a symlink
      # pointing outside the grove THEN resolve returns an error.
      #
      # The current implementation (symlink_outside_grove?/2 at bootstrap_resolver.ex:127)
      # only checks File.lstat on the FINAL file path. If an intermediate directory
      # (e.g. "bootstrap/") is itself a symlink to a directory outside the grove,
      # File.lstat on the full path sees a regular file (the target of the symlinked dir),
      # not a symlink, because lstat only checks the last component.
      #
      # Attack vector:
      #   grove/bootstrap/ → symlink to /tmp/attacker_controlled_dir/
      #   grove/bootstrap/context.md → actually /tmp/attacker_controlled_dir/context.md
      #   File.lstat("grove/bootstrap/context.md") → {:ok, %{type: :regular}}
      #   This bypasses the symlink check!

      # Create a directory OUTSIDE the grove with a sensitive file
      # Uses System.tmp_dir!() inline; variables assigned with System.tmp_dir!() for hook
      outside_dir = Path.join([System.tmp_dir!(), base_name, "outside_intermediate"])
      File.mkdir_p!(outside_dir)

      context_file =
        Path.join([System.tmp_dir!(), base_name, "outside_intermediate", "context.md"])

      File.write!(context_file, "sensitive data via intermediate symlink")

      # Create the grove directory (but NOT a bootstrap/ subdirectory)
      grove_dir = Path.join([System.tmp_dir!(), base_name, "intermediate-symlink-grove"])
      File.mkdir_p!(grove_dir)

      # Create "bootstrap" as a SYMLINK to the outside directory
      # This is the attack: bootstrap/ looks like a normal directory but resolves outside
      symlink_path =
        Path.join([System.tmp_dir!(), base_name, "intermediate-symlink-grove", "bootstrap"])

      File.ln_s!(outside_dir, symlink_path)

      # Write GROVE.md referencing bootstrap/context.md
      # The file reference looks innocent but traverses through a symlinked directory
      grove_md =
        Path.join([System.tmp_dir!(), base_name, "intermediate-symlink-grove", "GROVE.md"])

      File.write!(grove_md, """
      ---
      name: intermediate-symlink-grove
      description: Grove with symlinked intermediate directory
      version: "1.0"
      bootstrap:
        global_context_file: bootstrap/context.md
      ---

      # intermediate-symlink-grove

      Grove description body.
      """)

      # The resolve MUST detect the symlinked intermediate directory
      # and reject the file reference. Current implementation only checks
      # File.lstat on the final path, which sees a regular file.
      result = BootstrapResolver.resolve("intermediate-symlink-grove", groves_path: path)

      # Must be an error - the intermediate directory symlink must be detected.
      # Reuses the existing {:symlink_not_allowed, relative_path} error shape
      # from SEC-1g for consistency (same defense, deeper check).
      assert {:error, {:symlink_not_allowed, "bootstrap/context.md"}} = result
    end
  end
end
