defmodule Quoracle.Models.TableSecretsValidationTest do
  @moduledoc """
  Tests for TableSecrets validation consistency.
  Ensures model layer validation matches UI layer requirements.
  """
  use Quoracle.DataCase, async: true

  alias Quoracle.Models.TableSecrets

  describe "name validation consistency" do
    # TEST: Model should reject single-character names (min: 2)
    test "rejects single-character names to match LiveView validation" do
      attrs = %{
        name: "a",
        value: "secret123",
        description: "Single char name"
      }

      {:error, changeset} = TableSecrets.create(attrs)

      assert %{name: ["should be at least 2 character(s)"]} = errors_on(changeset)
      refute changeset.valid?
    end

    test "accepts two-character names as minimum" do
      attrs = %{
        name: "ab",
        value: "secret123",
        description: "Two char name"
      }

      assert {:ok, secret} = TableSecrets.create(attrs)
      assert secret.name == "ab"
    end

    test "validates maximum length of 64 characters" do
      attrs = %{
        name: String.duplicate("a", 65),
        value: "secret123"
      }

      {:error, changeset} = TableSecrets.create(attrs)

      assert %{name: ["should be at most 64 character(s)"]} = errors_on(changeset)
    end

    test "enforces alphanumeric with underscores only format" do
      invalid_names = [
        "with spaces",
        "special@chars",
        "dash-not-allowed",
        "dots.not.allowed"
      ]

      for invalid_name <- invalid_names do
        attrs = %{name: invalid_name, value: "secret123"}
        {:error, changeset} = TableSecrets.create(attrs)

        assert %{name: ["must be alphanumeric with underscores only"]} = errors_on(changeset),
               "Expected #{invalid_name} to be rejected"
      end
    end

    # TEST: Validation should match exactly between create and update
    test "update validation matches create validation for name length" do
      # First create with valid name
      {:ok, secret} =
        TableSecrets.create(%{
          name: "test_secret",
          value: "initial"
        })

      # Try to update with single character name (should fail)
      {:error, changeset} =
        TableSecrets.update(secret.name, %{
          name: "x",
          value: "updated"
        })

      assert %{name: ["should be at least 2 character(s)"]} = errors_on(changeset)
    end
  end

  describe "changeset/2 function exposure" do
    # TEST: Changeset function should be accessible for consistent validation
    test "changeset function is public for LiveView validation reuse" do
      # This tests that we can access the changeset function directly
      # to avoid duplicating validation logic
      changeset =
        TableSecrets.changeset(%TableSecrets{}, %{
          name: "a",
          value: "test"
        })

      refute changeset.valid?
      assert %{name: ["should be at least 2 character(s)"]} = errors_on(changeset)
    end
  end
end
