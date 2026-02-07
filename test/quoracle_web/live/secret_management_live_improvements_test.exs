defmodule QuoracleWeb.SecretManagementLiveImprovementsTest do
  @moduledoc """
  Tests for SecretManagementLive improvements addressing audit findings.
  Verifies proper validation and efficient queries.
  """
  use QuoracleWeb.ConnCase, async: true
  import Phoenix.LiveViewTest, except: [live_isolated: 2, live_isolated: 3]

  alias Quoracle.Models.{TableSecrets, TableCredentials}

  setup do
    # Create isolated PubSub for each test
    pubsub = :"test_pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub})
    %{pubsub: pubsub}
  end

  defp mount_secret_management_live(conn, sandbox_owner, pubsub) do
    live_isolated(conn, QuoracleWeb.SecretManagementLive,
      session: %{
        "sandbox_owner" => sandbox_owner,
        "pubsub" => pubsub,
        "topic" => "secrets:test_#{System.unique_integer()}"
      }
    )
  end

  describe "validation consistency between UI and Model" do
    test "LiveView uses TableSecrets.changeset/2 for validation", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      # Switch to secrets tab (credentials is now default)
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='secrets']")
      |> render_click()

      # Open new secret modal
      view |> element("button", "Add Secret") |> render_click()

      # TEST: Single character name should be rejected (matching model validation)
      result =
        view
        |> form("#secret-form", %{
          secret: %{
            name: "a",
            value: "test123"
          }
        })
        |> render_submit()

      # Validation should prevent submission (form stays open or shows error)
      refute result =~ "Secret created"
    end

    test "model layer rejects single-character names", %{
      sandbox_owner: _sandbox_owner
    } do
      # TEST: Model layer rejects single-character names
      assert {:error, _changeset} =
               TableSecrets.create(%{
                 name: "a",
                 value: "test123"
               })
    end
  end

  describe "efficient query patterns in LiveView" do
    setup do
      # Create multiple credentials for testing (no FK to model_configs)
      credentials =
        for i <- 1..25 do
          {:ok, cred} =
            TableCredentials.insert(%{
              model_id: "model_#{i}",
              model_spec: "openai:model_#{i}",
              api_key: "key_#{i}"
            })

          cred
        end

      %{credentials: credentials}
    end

    test "get_by_id retrieves credentials efficiently", %{
      credentials: [first_cred | _]
    } do
      # TEST: Model layer has efficient get_by_id function
      {:ok, fetched} = TableCredentials.get_by_id(first_cred.id)
      assert fetched.id == first_cred.id
      assert fetched.model_id == first_cred.model_id
    end

    test "pagination supported at model layer", %{
      credentials: _credentials
    } do
      # TEST: Model layer supports pagination
      page1 = TableCredentials.list_all(page: 1, page_size: 10)
      assert length(page1) == 10

      page2 = TableCredentials.list_all(page: 2, page_size: 10)
      assert length(page2) == 10

      # Verify pages don't overlap
      page1_ids = MapSet.new(page1, & &1.id)
      page2_ids = MapSet.new(page2, & &1.id)
      assert MapSet.disjoint?(page1_ids, page2_ids)
    end

    test "get_by_id returns error for non-existent ID" do
      non_existent = Ecto.UUID.generate()
      assert {:error, :not_found} = TableCredentials.get_by_id(non_existent)
    end
  end

  describe "credential deletion" do
    test "can delete credential directly", %{
      conn: conn,
      sandbox_owner: sandbox_owner,
      pubsub: pubsub
    } do
      # Create a credential
      {:ok, cred} =
        TableCredentials.insert(%{
          model_id: "deletable_model",
          model_spec: "openai:deletable_model",
          api_key: "deletable-key"
        })

      {:ok, view, _html} = mount_secret_management_live(conn, sandbox_owner, pubsub)

      # Switch to credentials tab (tab interface added in Packet 4)
      view
      |> element("[phx-click='switch_tab'][phx-value-tab='credentials']")
      |> render_click()

      # Verify credential is shown
      assert render(view) =~ "deletable_model"

      # Click delete on the credential
      view
      |> element("[data-action='delete'][data-id='#{cred.id}']")
      |> render_click()

      # Confirm deletion
      view
      |> element("#confirm-delete-button")
      |> render_click()

      # Credential should be deleted (no error shown)
      refute has_element?(view, ".error-message")
    end
  end
end
