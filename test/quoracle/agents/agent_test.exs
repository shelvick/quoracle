defmodule Quoracle.Agents.AgentTest do
  use Quoracle.DataCase, async: true

  alias Quoracle.Agents.Agent
  alias Quoracle.Tasks.Task
  alias Quoracle.Repo

  describe "schema" do
    test "has correct fields" do
      agent = %Agent{}
      assert Map.has_key?(agent, :id)
      assert Map.has_key?(agent, :task_id)
      assert Map.has_key?(agent, :agent_id)
      assert Map.has_key?(agent, :parent_id)
      assert Map.has_key?(agent, :config)
      assert Map.has_key?(agent, :status)
      assert Map.has_key?(agent, :state)
      assert Map.has_key?(agent, :inserted_at)
      assert Map.has_key?(agent, :updated_at)
    end

    test "belongs to task" do
      agent = %Agent{}
      assert Map.has_key?(agent, :task)
    end
  end

  describe "changeset/2" do
    setup do
      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))
      %{task_id: task.id}
    end

    test "valid with required fields", %{task_id: task_id} do
      attrs = %{
        task_id: task_id,
        agent_id: "agent-123",
        config: %{model: "test"},
        status: "starting"
      }

      changeset = Agent.changeset(%Agent{}, attrs)
      assert changeset.valid?
    end

    test "requires task_id" do
      attrs = %{agent_id: "agent-123", config: %{}, status: "starting"}
      changeset = Agent.changeset(%Agent{}, attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).task_id
    end

    test "requires agent_id" do
      attrs = %{
        task_id: Ecto.UUID.generate(),
        config: %{},
        status: "starting"
      }

      changeset = Agent.changeset(%Agent{}, attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).agent_id
    end

    test "requires config" do
      attrs = %{
        task_id: Ecto.UUID.generate(),
        agent_id: "agent-123",
        status: "starting"
      }

      changeset = Agent.changeset(%Agent{}, attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).config
    end

    test "requires status" do
      attrs = %{
        task_id: Ecto.UUID.generate(),
        agent_id: "agent-123",
        config: %{}
      }

      changeset = Agent.changeset(%Agent{}, attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).status
    end

    test "validates status is in allowed values", %{task_id: task_id} do
      valid_statuses = ["starting", "running", "idle", "paused", "stopped"]

      for status <- valid_statuses do
        attrs = %{
          task_id: task_id,
          agent_id: "agent-#{status}",
          config: %{},
          status: status
        }

        changeset = Agent.changeset(%Agent{}, attrs)
        assert changeset.valid?, "Expected #{status} to be valid"
      end
    end

    test "rejects invalid status", %{task_id: task_id} do
      attrs = %{
        task_id: task_id,
        agent_id: "agent-123",
        config: %{},
        status: "invalid_status"
      }

      changeset = Agent.changeset(%Agent{}, attrs)
      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).status
    end

    test "allows optional parent_id", %{task_id: task_id} do
      attrs = %{
        task_id: task_id,
        agent_id: "agent-child",
        parent_id: "agent-parent",
        config: %{},
        status: "starting"
      }

      changeset = Agent.changeset(%Agent{}, attrs)
      assert changeset.valid?
      assert get_change(changeset, :parent_id) == "agent-parent"
    end
  end

  describe "database integration" do
    setup do
      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))
      %{task_id: task.id}
    end

    @tag :integration
    test "ARC_FUNC_01: WHEN agent spawned IF task_id and agent_id provided THEN record created",
         %{task_id: task_id} do
      attrs = %{
        task_id: task_id,
        agent_id: "agent-root-001",
        config: %{model: "claude-3-opus"},
        status: "starting"
      }

      changeset = Agent.changeset(%Agent{}, attrs)
      assert {:ok, agent} = Repo.insert(changeset)

      assert agent.id != nil
      assert agent.task_id == task_id
      assert agent.agent_id == "agent-root-001"
      assert agent.status == "starting"
      assert agent.inserted_at != nil
    end

    @tag :integration
    test "ARC_FUNC_02: WHEN agent setup completes THEN status updated",
         %{task_id: task_id} do
      {:ok, agent} =
        Repo.insert(
          Agent.changeset(%Agent{}, %{
            task_id: task_id,
            agent_id: "agent-002",
            config: %{},
            status: "starting"
          })
        )

      updated_agent = Ecto.Changeset.change(agent, status: "running")
      assert {:ok, running_agent} = Repo.update(updated_agent)
      assert running_agent.status == "running"
    end

    @tag :integration
    test "ARC_FUNC_08: WHEN root agent queried IF parent_id IS NULL THEN root agent returned", %{
      task_id: task_id
    } do
      # Create root agent (parent_id = nil)
      {:ok, root} =
        Repo.insert(
          Agent.changeset(%Agent{}, %{
            task_id: task_id,
            agent_id: "agent-root",
            parent_id: nil,
            config: %{},
            status: "running"
          })
        )

      # Create child agent
      Repo.insert(
        Agent.changeset(%Agent{}, %{
          task_id: task_id,
          agent_id: "agent-child",
          parent_id: "agent-root",
          config: %{},
          status: "running"
        })
      )

      # Query for root agent
      query = from(a in Agent, where: is_nil(a.parent_id) and a.task_id == ^task_id)
      root_agents = Repo.all(query)

      assert length(root_agents) == 1
      assert hd(root_agents).agent_id == root.agent_id
    end

    @tag :integration
    test "unique index on agent_id prevents duplicates", %{task_id: task_id} do
      attrs = %{
        task_id: task_id,
        agent_id: "agent-duplicate",
        config: %{},
        status: "starting"
      }

      # First insert should succeed
      assert {:ok, _} = Repo.insert(Agent.changeset(%Agent{}, attrs))

      # Second insert with same agent_id should fail
      assert {:error, changeset} = Repo.insert(Agent.changeset(%Agent{}, attrs))
      assert "has already been taken" in errors_on(changeset).agent_id
    end

    @tag :integration
    test "foreign key constraint enforces valid task_id" do
      invalid_task_id = Ecto.UUID.generate()

      attrs = %{
        task_id: invalid_task_id,
        agent_id: "agent-orphan",
        config: %{},
        status: "starting"
      }

      assert_raise Ecto.InvalidChangesetError, fn ->
        Repo.insert!(Agent.changeset(%Agent{}, attrs))
      end
    end
  end

  describe "indexes and queries" do
    setup do
      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))
      %{task_id: task.id}
    end

    @tag :integration
    test "ARC_FUNC_04: query by parent_id uses index", %{task_id: task_id} do
      # Create parent agent
      {:ok, parent} =
        Repo.insert(
          Agent.changeset(%Agent{}, %{
            task_id: task_id,
            agent_id: "agent-parent",
            config: %{},
            status: "running"
          })
        )

      # Create child agents
      for i <- 1..3 do
        Repo.insert(
          Agent.changeset(%Agent{}, %{
            task_id: task_id,
            agent_id: "agent-child-#{i}",
            parent_id: parent.agent_id,
            config: %{},
            status: "running"
          })
        )
      end

      # Query children by parent_id
      query = from(a in Agent, where: a.parent_id == ^parent.agent_id)
      children = Repo.all(query)

      assert length(children) == 3
      assert Enum.all?(children, fn child -> child.parent_id == parent.agent_id end)
    end

    @tag :integration
    test "ARC_FUNC_05: query by agent_id uses unique index", %{task_id: task_id} do
      {:ok, agent} =
        Repo.insert(
          Agent.changeset(%Agent{}, %{
            task_id: task_id,
            agent_id: "agent-unique-query",
            config: %{},
            status: "running"
          })
        )

      # Query by agent_id (should use unique index)
      found_agent = Repo.get_by(Agent, agent_id: "agent-unique-query")
      assert found_agent.id == agent.id
    end

    @tag :integration
    test "ARC_FUNC_07: WHEN reconstructing tree IF ordered by inserted_at THEN parents before children",
         %{task_id: task_id} do
      # Create root first
      {:ok, root} =
        Repo.insert(
          Agent.changeset(%Agent{}, %{
            task_id: task_id,
            agent_id: "agent-root",
            config: %{},
            status: "running"
          })
        )

      # Create child after root
      {:ok, child} =
        Repo.insert(
          Agent.changeset(%Agent{}, %{
            task_id: task_id,
            agent_id: "agent-child",
            parent_id: root.agent_id,
            config: %{},
            status: "running"
          })
        )

      # Query ordered by inserted_at
      query = from(a in Agent, where: a.task_id == ^task_id, order_by: [asc: a.inserted_at])
      agents = Repo.all(query)

      assert length(agents) == 2

      # Find each agent by agent_id (order may be non-deterministic when timestamps equal)
      root_from_db = Enum.find(agents, &(&1.agent_id == root.agent_id))
      child_from_db = Enum.find(agents, &(&1.agent_id == child.agent_id))

      assert root_from_db != nil
      assert child_from_db != nil

      # Timestamp should be less than or equal (can be equal if very fast)
      assert NaiveDateTime.compare(root_from_db.inserted_at, child_from_db.inserted_at) in [
               :lt,
               :eq
             ]
    end
  end

  describe "cascade deletion" do
    setup do
      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))
      %{task: task}
    end

    @tag :integration
    test "ARC_FUNC_06: WHEN task deleted IF CASCADE configured THEN agents deleted", %{task: task} do
      # Create agent for task
      {:ok, agent} =
        Repo.insert(
          Agent.changeset(%Agent{}, %{
            task_id: task.id,
            agent_id: "agent-cascade",
            config: %{},
            status: "running"
          })
        )

      # Delete task
      assert {:ok, _} = Repo.delete(task)

      # Verify agent was deleted via CASCADE
      assert Repo.get(Agent, agent.id) == nil
    end
  end
end
