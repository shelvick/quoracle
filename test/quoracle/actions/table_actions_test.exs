defmodule Quoracle.Actions.TableActionsTest do
  # Database tests can run async with modern Ecto.Sandbox pattern
  use Quoracle.DataCase, async: true
  alias Quoracle.Actions.TableActions
  alias Quoracle.Repo

  describe "schema definition" do
    test "has correct primary key configuration" do
      assert TableActions.__schema__(:primary_key) == [:id]
      assert TableActions.__schema__(:type, :id) == :binary_id
    end

    test "has all required fields" do
      fields = TableActions.__schema__(:fields)

      required_fields = [
        :id,
        :agent_id,
        :action_type,
        :params,
        :reasoning,
        :result,
        :status,
        :started_at,
        :completed_at,
        :error_message,
        :parent_action_id,
        :inserted_at,
        :updated_at
      ]

      Enum.each(required_fields, fn field ->
        assert field in fields, "Missing field: #{field}"
      end)
    end

    test "has correct field types" do
      assert TableActions.__schema__(:type, :agent_id) == :binary_id
      assert TableActions.__schema__(:type, :action_type) == :string
      assert TableActions.__schema__(:type, :params) == :map
      assert TableActions.__schema__(:type, :reasoning) == :string
      assert TableActions.__schema__(:type, :result) == :map
      assert TableActions.__schema__(:type, :status) == :string
      assert TableActions.__schema__(:type, :started_at) == :utc_datetime_usec
      assert TableActions.__schema__(:type, :completed_at) == :utc_datetime_usec
      assert TableActions.__schema__(:type, :error_message) == :string
      assert TableActions.__schema__(:type, :parent_action_id) == :binary_id
    end

    test "has parent_action association" do
      assoc = TableActions.__schema__(:association, :parent_action)
      assert assoc.cardinality == :one
      assert assoc.relationship == :parent
      assert assoc.related == TableActions
    end
  end

  describe "changeset/2" do
    test "validates required fields" do
      changeset = TableActions.changeset(%TableActions{}, %{})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).agent_id
      assert "can't be blank" in errors_on(changeset).action_type
      assert "can't be blank" in errors_on(changeset).params
      assert "can't be blank" in errors_on(changeset).status
      assert "can't be blank" in errors_on(changeset).started_at
    end

    test "validates action_type is one of allowed values" do
      valid_types = ~w(spawn_child wait send_message orient answer_engine
                       execute_shell fetch_web call_api call_mcp)

      for type <- valid_types do
        changeset =
          TableActions.changeset(%TableActions{}, %{
            agent_id: Ecto.UUID.generate(),
            action_type: type,
            params: %{},
            status: "pending",
            started_at: DateTime.utc_now()
          })

        assert changeset.valid?, "Should accept action_type: #{type}"
      end

      invalid_changeset =
        TableActions.changeset(%TableActions{}, %{
          agent_id: Ecto.UUID.generate(),
          action_type: "invalid_action",
          params: %{},
          status: "pending",
          started_at: DateTime.utc_now()
        })

      refute invalid_changeset.valid?
      assert "is invalid" in errors_on(invalid_changeset).action_type
    end

    test "validates status is one of allowed values" do
      valid_statuses = ~w(pending running completed failed)

      for status <- valid_statuses do
        attrs = %{
          agent_id: Ecto.UUID.generate(),
          action_type: "spawn_child",
          params: %{},
          status: status,
          started_at: DateTime.utc_now()
        }

        # Add required fields for terminal statuses
        attrs =
          case status do
            "completed" ->
              Map.put(attrs, :completed_at, DateTime.utc_now())

            "failed" ->
              attrs
              |> Map.put(:completed_at, DateTime.utc_now())
              |> Map.put(:error_message, "Test error")

            _ ->
              attrs
          end

        changeset = TableActions.changeset(%TableActions{}, attrs)
        assert changeset.valid?, "Should accept status: #{status}"
      end

      invalid_changeset =
        TableActions.changeset(%TableActions{}, %{
          agent_id: Ecto.UUID.generate(),
          action_type: "spawn_child",
          params: %{},
          status: "invalid_status",
          started_at: DateTime.utc_now()
        })

      refute invalid_changeset.valid?
      assert "is invalid" in errors_on(invalid_changeset).status
    end

    test "accepts optional fields" do
      changeset =
        TableActions.changeset(%TableActions{}, %{
          agent_id: Ecto.UUID.generate(),
          action_type: "spawn_child",
          params: %{"task" => "Process data"},
          status: "completed",
          started_at: DateTime.utc_now(),
          reasoning: "Need to delegate processing",
          result: %{"child_id" => Ecto.UUID.generate()},
          completed_at: DateTime.utc_now(),
          parent_action_id: Ecto.UUID.generate()
        })

      assert changeset.valid?
    end

    test "validates UUID format for binary_id fields" do
      changeset =
        TableActions.changeset(%TableActions{}, %{
          agent_id: "not-a-uuid",
          action_type: "spawn_child",
          params: %{},
          status: "pending",
          started_at: DateTime.utc_now()
        })

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).agent_id
    end

    test "validates completed_at is after started_at when both present" do
      started = DateTime.utc_now()
      # 1 hour before
      completed = DateTime.add(started, -3600, :second)

      changeset =
        TableActions.changeset(%TableActions{}, %{
          agent_id: Ecto.UUID.generate(),
          action_type: "wait",
          params: %{},
          status: "completed",
          started_at: started,
          completed_at: completed
        })

      refute changeset.valid?
      assert "must be after started_at" in errors_on(changeset).completed_at
    end

    test "requires error_message when status is failed" do
      changeset =
        TableActions.changeset(%TableActions{}, %{
          agent_id: Ecto.UUID.generate(),
          action_type: "execute_shell",
          params: %{"command" => "invalid"},
          status: "failed",
          started_at: DateTime.utc_now(),
          completed_at: DateTime.utc_now()
        })

      refute changeset.valid?
      assert "can't be blank when status is failed" in errors_on(changeset).error_message
    end

    test "requires completed_at when status is completed or failed" do
      for status <- ["completed", "failed"] do
        changeset =
          TableActions.changeset(%TableActions{}, %{
            agent_id: Ecto.UUID.generate(),
            action_type: "wait",
            params: %{},
            status: status,
            started_at: DateTime.utc_now(),
            error_message: if(status == "failed", do: "Error", else: nil)
          })

        refute changeset.valid?
        assert "can't be blank when status is #{status}" in errors_on(changeset).completed_at
      end
    end
  end

  describe "create_action/1" do
    test "creates action with valid attributes" do
      attrs = %{
        agent_id: Ecto.UUID.generate(),
        action_type: "spawn_child",
        params: %{"task" => "Process data"},
        reasoning: "Need parallel processing",
        status: "pending",
        started_at: DateTime.utc_now()
      }

      assert {:ok, action} = TableActions.create_action(attrs)
      assert action.id
      assert action.agent_id == attrs.agent_id
      assert action.action_type == attrs.action_type
      assert action.params == attrs.params
      assert action.reasoning == attrs.reasoning
      assert action.status == attrs.status
    end

    test "returns error changeset for invalid attributes" do
      attrs = %{action_type: "invalid"}

      assert {:error, changeset} = TableActions.create_action(attrs)
      refute changeset.valid?
    end
  end

  describe "update_action/2" do
    setup do
      action =
        %TableActions{
          id: Ecto.UUID.generate(),
          agent_id: Ecto.UUID.generate(),
          action_type: "wait",
          params: %{},
          status: "running",
          started_at: DateTime.utc_now()
        }
        |> Repo.insert!()

      {:ok, action: action}
    end

    test "updates action status to completed", %{action: action} do
      attrs = %{
        status: "completed",
        completed_at: DateTime.utc_now(),
        result: %{"wait" => 1000}
      }

      assert {:ok, updated} = TableActions.update_action(action, attrs)
      assert updated.status == "completed"
      assert updated.completed_at
      assert updated.result == attrs.result
    end

    test "updates action status to failed with error", %{action: action} do
      attrs = %{
        status: "failed",
        completed_at: DateTime.utc_now(),
        error_message: "Timeout exceeded"
      }

      assert {:ok, updated} = TableActions.update_action(action, attrs)
      assert updated.status == "failed"
      assert updated.error_message == "Timeout exceeded"
    end

    test "validates status transitions", %{action: action} do
      # Can't go from running back to pending
      attrs = %{status: "pending"}

      assert {:error, changeset} = TableActions.update_action(action, attrs)
      assert "invalid status transition" in errors_on(changeset).status
    end
  end

  describe "get_action/1" do
    setup do
      action =
        %TableActions{
          id: Ecto.UUID.generate(),
          agent_id: Ecto.UUID.generate(),
          action_type: "answer_engine",
          params: %{"prompt" => "Explain quantum computing"},
          status: "completed",
          started_at: DateTime.utc_now(),
          completed_at: DateTime.utc_now()
        }
        |> Repo.insert!()

      {:ok, action: action}
    end

    test "returns action by id", %{action: action} do
      found = TableActions.get_action(action.id)
      assert found.id == action.id
      assert found.action_type == action.action_type
    end

    test "returns nil for non-existent id" do
      assert nil == TableActions.get_action(Ecto.UUID.generate())
    end

    test "preloads parent_action when requested", %{action: parent} do
      child =
        %TableActions{
          id: Ecto.UUID.generate(),
          agent_id: parent.agent_id,
          action_type: "spawn_child",
          params: %{},
          status: "running",
          started_at: DateTime.utc_now(),
          parent_action_id: parent.id
        }
        |> Repo.insert!()

      found = TableActions.get_action(child.id, preload: [:parent_action])
      assert found.parent_action.id == parent.id
    end
  end

  describe "list_actions_for_agent/2" do
    setup do
      agent_id = Ecto.UUID.generate()
      other_agent_id = Ecto.UUID.generate()

      # Create actions for our agent
      actions =
        for i <- 1..5 do
          %TableActions{
            id: Ecto.UUID.generate(),
            agent_id: agent_id,
            action_type: "wait",
            params: %{"wait" => i * 1000},
            status: "completed",
            started_at: DateTime.add(DateTime.utc_now(), -i * 3600, :second),
            completed_at: DateTime.utc_now()
          }
          |> Repo.insert!()
        end

      # Create action for different agent
      %TableActions{
        id: Ecto.UUID.generate(),
        agent_id: other_agent_id,
        action_type: "wait",
        params: %{},
        status: "completed",
        started_at: DateTime.utc_now(),
        completed_at: DateTime.utc_now()
      }
      |> Repo.insert!()

      {:ok, agent_id: agent_id, actions: actions}
    end

    test "returns actions for specific agent", %{agent_id: agent_id} do
      results = TableActions.list_actions_for_agent(agent_id)

      assert length(results) == 5
      assert Enum.all?(results, &(&1.agent_id == agent_id))
    end

    test "returns actions ordered by started_at desc", %{agent_id: agent_id} do
      results = TableActions.list_actions_for_agent(agent_id)

      timestamps = Enum.map(results, & &1.started_at)
      assert timestamps == Enum.sort(timestamps, {:desc, DateTime})
    end

    test "respects limit option", %{agent_id: agent_id} do
      results = TableActions.list_actions_for_agent(agent_id, limit: 2)

      assert length(results) == 2
    end

    test "filters by status when provided", %{agent_id: agent_id} do
      # Create a pending action
      %TableActions{
        id: Ecto.UUID.generate(),
        agent_id: agent_id,
        action_type: "spawn_child",
        params: %{},
        status: "pending",
        started_at: DateTime.utc_now()
      }
      |> Repo.insert!()

      results = TableActions.list_actions_for_agent(agent_id, status: "pending")

      assert length(results) == 1
      assert hd(results).status == "pending"
    end
  end

  describe "list_failed_actions/1" do
    setup do
      now = DateTime.utc_now()

      # Create recent failed action
      recent_failed =
        %TableActions{
          id: Ecto.UUID.generate(),
          agent_id: Ecto.UUID.generate(),
          action_type: "execute_shell",
          params: %{"command" => "fail"},
          status: "failed",
          # 30 min ago
          started_at: DateTime.add(now, -1800, :second),
          completed_at: now,
          error_message: "Command not found"
        }
        |> Repo.insert!()

      # Create old failed action
      %TableActions{
        id: Ecto.UUID.generate(),
        agent_id: Ecto.UUID.generate(),
        action_type: "fetch_web",
        params: %{"url" => "http://invalid"},
        status: "failed",
        # 2 hours ago
        started_at: DateTime.add(now, -7200, :second),
        completed_at: DateTime.add(now, -7000, :second),
        error_message: "Connection refused"
      }
      |> Repo.insert!()

      # Create successful action
      %TableActions{
        id: Ecto.UUID.generate(),
        agent_id: Ecto.UUID.generate(),
        action_type: "wait",
        params: %{},
        status: "completed",
        started_at: DateTime.add(now, -600, :second),
        completed_at: now
      }
      |> Repo.insert!()

      {:ok, recent_failed: recent_failed}
    end

    test "returns failed actions within time window", %{recent_failed: recent} do
      results = TableActions.list_failed_actions(hours: 1)

      assert length(results) == 1
      assert hd(results).id == recent.id
      assert hd(results).status == "failed"
    end

    test "includes all failed actions when no time limit" do
      results = TableActions.list_failed_actions()

      assert length(results) == 2
      assert Enum.all?(results, &(&1.status == "failed"))
    end
  end

  describe "list_child_actions/1" do
    setup do
      parent =
        %TableActions{
          id: Ecto.UUID.generate(),
          agent_id: Ecto.UUID.generate(),
          action_type: "spawn_child",
          params: %{"task" => "Parent task"},
          status: "completed",
          started_at: DateTime.utc_now(),
          completed_at: DateTime.utc_now()
        }
        |> Repo.insert!()

      children =
        for i <- 1..3 do
          %TableActions{
            id: Ecto.UUID.generate(),
            agent_id: Ecto.UUID.generate(),
            action_type: "wait",
            params: %{"wait" => i * 100},
            status: "completed",
            started_at: DateTime.utc_now(),
            completed_at: DateTime.utc_now(),
            parent_action_id: parent.id
          }
          |> Repo.insert!()
        end

      # Create unrelated action
      %TableActions{
        id: Ecto.UUID.generate(),
        agent_id: Ecto.UUID.generate(),
        action_type: "wait",
        params: %{},
        status: "completed",
        started_at: DateTime.utc_now(),
        completed_at: DateTime.utc_now()
      }
      |> Repo.insert!()

      {:ok, parent: parent, children: children}
    end

    test "returns all child actions for parent", %{parent: parent, children: children} do
      results = TableActions.list_child_actions(parent.id)

      assert length(results) == 3
      assert Enum.all?(results, &(&1.parent_action_id == parent.id))

      result_ids = MapSet.new(results, & &1.id)
      child_ids = MapSet.new(children, & &1.id)
      assert MapSet.equal?(result_ids, child_ids)
    end

    test "returns empty list for action with no children" do
      childless =
        %TableActions{
          id: Ecto.UUID.generate(),
          agent_id: Ecto.UUID.generate(),
          action_type: "wait",
          params: %{},
          status: "completed",
          started_at: DateTime.utc_now(),
          completed_at: DateTime.utc_now()
        }
        |> Repo.insert!()

      results = TableActions.list_child_actions(childless.id)
      assert results == []
    end

    test "preloads parent_action when requested", %{parent: parent} do
      results = TableActions.list_child_actions(parent.id, preload: [:parent_action])

      assert Enum.all?(results, fn child ->
               child.parent_action.id == parent.id
             end)
    end
  end

  describe "delete_action/1" do
    setup do
      action =
        %TableActions{
          id: Ecto.UUID.generate(),
          agent_id: Ecto.UUID.generate(),
          action_type: "orient",
          params: %{},
          status: "completed",
          started_at: DateTime.utc_now(),
          completed_at: DateTime.utc_now()
        }
        |> Repo.insert!()

      {:ok, action: action}
    end

    test "deletes the action", %{action: action} do
      assert {:ok, deleted} = TableActions.delete_action(action)
      assert deleted.id == action.id

      assert nil == TableActions.get_action(action.id)
    end

    test "returns error if action has children" do
      parent =
        %TableActions{
          id: Ecto.UUID.generate(),
          agent_id: Ecto.UUID.generate(),
          action_type: "spawn_child",
          params: %{},
          status: "completed",
          started_at: DateTime.utc_now(),
          completed_at: DateTime.utc_now()
        }
        |> Repo.insert!()

      %TableActions{
        id: Ecto.UUID.generate(),
        agent_id: Ecto.UUID.generate(),
        action_type: "wait",
        params: %{},
        status: "completed",
        started_at: DateTime.utc_now(),
        completed_at: DateTime.utc_now(),
        parent_action_id: parent.id
      }
      |> Repo.insert!()

      assert {:error, changeset} = TableActions.delete_action(parent)
      assert "has child actions" in errors_on(changeset).base
    end
  end

  describe "count_actions_by_status/1" do
    setup do
      agent_id = Ecto.UUID.generate()

      # Create actions with different statuses
      for _ <- 1..3 do
        %TableActions{
          id: Ecto.UUID.generate(),
          agent_id: agent_id,
          action_type: "wait",
          params: %{},
          status: "completed",
          started_at: DateTime.utc_now(),
          completed_at: DateTime.utc_now()
        }
        |> Repo.insert!()
      end

      for _ <- 1..2 do
        %TableActions{
          id: Ecto.UUID.generate(),
          agent_id: agent_id,
          action_type: "wait",
          params: %{},
          status: "running",
          started_at: DateTime.utc_now()
        }
        |> Repo.insert!()
      end

      %TableActions{
        id: Ecto.UUID.generate(),
        agent_id: agent_id,
        action_type: "execute_shell",
        params: %{},
        status: "failed",
        started_at: DateTime.utc_now(),
        completed_at: DateTime.utc_now(),
        error_message: "Error"
      }
      |> Repo.insert!()

      {:ok, agent_id: agent_id}
    end

    test "returns count by status for agent", %{agent_id: agent_id} do
      result = TableActions.count_actions_by_status(agent_id)

      assert result == %{
               "completed" => 3,
               "running" => 2,
               "failed" => 1,
               "pending" => 0
             }
    end

    test "returns zeros for agent with no actions" do
      result = TableActions.count_actions_by_status(Ecto.UUID.generate())

      assert result == %{
               "completed" => 0,
               "running" => 0,
               "failed" => 0,
               "pending" => 0
             }
    end
  end
end
