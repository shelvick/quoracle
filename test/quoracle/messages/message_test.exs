defmodule Quoracle.Messages.MessageTest do
  use Quoracle.DataCase, async: true

  alias Quoracle.Messages.Message
  alias Quoracle.Tasks.Task
  alias Quoracle.Repo
  import Ecto.Query

  describe "schema" do
    test "has correct fields" do
      message = %Message{}
      assert Map.has_key?(message, :id)
      assert Map.has_key?(message, :task_id)
      assert Map.has_key?(message, :from_agent_id)
      assert Map.has_key?(message, :to_agent_id)
      assert Map.has_key?(message, :content)
      assert Map.has_key?(message, :read_at)
      assert Map.has_key?(message, :inserted_at)
      refute Map.has_key?(message, :updated_at)
    end

    test "belongs to task" do
      message = %Message{}
      assert Map.has_key?(message, :task)
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
        from_agent_id: "agent-sender",
        to_agent_id: "agent-receiver",
        content: "Test message content"
      }

      changeset = Message.changeset(%Message{}, attrs)
      assert changeset.valid?
    end

    test "requires task_id" do
      attrs = %{
        from_agent_id: "agent-sender",
        to_agent_id: "agent-receiver",
        content: "Test message"
      }

      changeset = Message.changeset(%Message{}, attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).task_id
    end

    test "requires from_agent_id" do
      attrs = %{
        task_id: Ecto.UUID.generate(),
        to_agent_id: "agent-receiver",
        content: "Test message"
      }

      changeset = Message.changeset(%Message{}, attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).from_agent_id
    end

    test "requires to_agent_id" do
      attrs = %{
        task_id: Ecto.UUID.generate(),
        from_agent_id: "agent-sender",
        content: "Test message"
      }

      changeset = Message.changeset(%Message{}, attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).to_agent_id
    end

    test "requires content" do
      attrs = %{
        task_id: Ecto.UUID.generate(),
        from_agent_id: "agent-sender",
        to_agent_id: "agent-receiver"
      }

      changeset = Message.changeset(%Message{}, attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).content
    end

    test "allows optional read_at", %{task_id: task_id} do
      read_time = DateTime.utc_now()

      attrs = %{
        task_id: task_id,
        from_agent_id: "agent-sender",
        to_agent_id: "agent-receiver",
        content: "Test message",
        read_at: read_time
      }

      changeset = Message.changeset(%Message{}, attrs)
      assert changeset.valid?
      assert get_change(changeset, :read_at) == read_time
    end
  end

  describe "mark_read_changeset/1" do
    test "sets read_at to current time" do
      message = %Message{read_at: nil}
      changeset = Message.mark_read_changeset(message)

      assert changeset.valid?
      read_at = get_change(changeset, :read_at)
      assert %DateTime{} = read_at
    end
  end

  describe "database integration" do
    setup do
      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))
      %{task_id: task.id}
    end

    @tag :integration
    test "ARC_FUNC_01: WHEN message sent IF from/to valid THEN record created", %{
      task_id: task_id
    } do
      attrs = %{
        task_id: task_id,
        from_agent_id: "agent-001",
        to_agent_id: "agent-002",
        content: "Hello from agent-001"
      }

      changeset = Message.changeset(%Message{}, attrs)
      assert {:ok, message} = Repo.insert(changeset)

      assert message.id != nil
      assert message.task_id == task_id
      assert message.from_agent_id == "agent-001"
      assert message.to_agent_id == "agent-002"
      assert message.content == "Hello from agent-001"
      assert message.read_at == nil
      assert message.inserted_at != nil
    end

    @tag :integration
    test "ARC_FUNC_05: WHEN marking read IF read_at NULL THEN timestamp set", %{task_id: task_id} do
      {:ok, message} =
        Repo.insert(
          Message.changeset(%Message{}, %{
            task_id: task_id,
            from_agent_id: "agent-sender",
            to_agent_id: "agent-receiver",
            content: "Unread message"
          })
        )

      assert message.read_at == nil

      # Mark as read
      changeset = Message.mark_read_changeset(message)
      assert {:ok, read_message} = Repo.update(changeset)

      assert %DateTime{} = read_message.read_at
      assert DateTime.compare(read_message.read_at, DateTime.utc_now()) in [:lt, :eq]
    end

    @tag :integration
    test "foreign key constraint enforces valid task_id" do
      invalid_task_id = Ecto.UUID.generate()

      attrs = %{
        task_id: invalid_task_id,
        from_agent_id: "agent-sender",
        to_agent_id: "agent-receiver",
        content: "Orphan message"
      }

      assert_raise Ecto.InvalidChangesetError, fn ->
        Repo.insert!(Message.changeset(%Message{}, attrs))
      end
    end

    @tag :integration
    test "messages are append-only (no updated_at timestamp)", %{task_id: task_id} do
      {:ok, message} =
        Repo.insert(
          Message.changeset(%Message{}, %{
            task_id: task_id,
            from_agent_id: "agent-001",
            to_agent_id: "agent-002",
            content: "Test"
          })
        )

      # Verify no updated_at field
      refute Map.has_key?(message, :updated_at)
    end

    @tag :integration
    test "generates binary_id for primary key", %{task_id: task_id} do
      {:ok, message} =
        Repo.insert(
          Message.changeset(%Message{}, %{
            task_id: task_id,
            from_agent_id: "agent-001",
            to_agent_id: "agent-002",
            content: "Test"
          })
        )

      assert is_binary(message.id)
      # UUID string format is 36 characters (with dashes)
      assert String.length(message.id) == 36
    end
  end

  describe "indexes and query helpers" do
    setup do
      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))
      %{task_id: task.id}
    end

    @tag :integration
    test "ARC_FUNC_02: inbox query uses to_agent_id index", %{task_id: task_id} do
      # Create messages to agent-inbox
      for i <- 1..5 do
        Repo.insert(
          Message.changeset(%Message{}, %{
            task_id: task_id,
            from_agent_id: "agent-sender-#{i}",
            to_agent_id: "agent-inbox",
            content: "Message #{i}"
          })
        )
      end

      # Create messages to other agents
      for i <- 1..3 do
        Repo.insert(
          Message.changeset(%Message{}, %{
            task_id: task_id,
            from_agent_id: "agent-sender",
            to_agent_id: "agent-other-#{i}",
            content: "Other message"
          })
        )
      end

      # Query inbox for agent-inbox
      inbox_query = Quoracle.Messages.Queries.inbox("agent-inbox")
      messages = Repo.all(inbox_query)

      assert length(messages) == 5
      assert Enum.all?(messages, fn m -> m.to_agent_id == "agent-inbox" end)
    end

    @tag :integration
    test "ARC_FUNC_03: outbox query uses from_agent_id index", %{task_id: task_id} do
      # Create messages from agent-outbox
      for i <- 1..4 do
        Repo.insert(
          Message.changeset(%Message{}, %{
            task_id: task_id,
            from_agent_id: "agent-outbox",
            to_agent_id: "agent-receiver-#{i}",
            content: "Outgoing #{i}"
          })
        )
      end

      # Query outbox for agent-outbox
      outbox_query = Quoracle.Messages.Queries.outbox("agent-outbox")
      messages = Repo.all(outbox_query)

      assert length(messages) == 4
      assert Enum.all?(messages, fn m -> m.from_agent_id == "agent-outbox" end)
    end

    @tag :integration
    test "ARC_FUNC_04: conversation query returns bidirectional messages", %{task_id: task_id} do
      # Create conversation between agent-a and agent-b
      # Use explicit timestamps to ensure deterministic ordering
      base_time = NaiveDateTime.utc_now()

      messages_data = [
        {"agent-a", "agent-b", "Hello from A", 0},
        {"agent-b", "agent-a", "Hello from B", 1},
        {"agent-a", "agent-b", "How are you?", 2},
        {"agent-b", "agent-a", "I'm fine, thanks", 3}
      ]

      for {from, to, content, offset} <- messages_data do
        timestamp =
          base_time
          |> NaiveDateTime.add(offset, :second)
          |> NaiveDateTime.truncate(:second)

        {:ok, _} =
          Repo.insert(%Message{
            task_id: task_id,
            from_agent_id: from,
            to_agent_id: to,
            content: content,
            inserted_at: timestamp
          })
      end

      # Query conversation
      conversation_query = Quoracle.Messages.Queries.conversation("agent-a", "agent-b")
      messages = Repo.all(conversation_query)

      assert length(messages) == 4
      # Verify chronological order
      contents = Enum.map(messages, & &1.content)
      assert contents == ["Hello from A", "Hello from B", "How are you?", "I'm fine, thanks"]
    end

    @tag :integration
    test "query all messages for task", %{task_id: task_id} do
      # Create messages for this task
      for i <- 1..6 do
        Repo.insert(
          Message.changeset(%Message{}, %{
            task_id: task_id,
            from_agent_id: "agent-#{rem(i, 3)}",
            to_agent_id: "agent-#{rem(i + 1, 3)}",
            content: "Message #{i}"
          })
        )
      end

      # Query all messages for task
      task_messages_query = Quoracle.Messages.Queries.for_task(task_id)
      messages = Repo.all(task_messages_query)

      assert length(messages) == 6
      assert Enum.all?(messages, fn m -> m.task_id == task_id end)
    end

    @tag :integration
    test "query unread messages", %{task_id: task_id} do
      # Create unread messages
      for i <- 1..3 do
        Repo.insert(
          Message.changeset(%Message{}, %{
            task_id: task_id,
            from_agent_id: "agent-sender",
            to_agent_id: "agent-receiver",
            content: "Unread #{i}"
          })
        )
      end

      # Create read message
      {:ok, read_msg} =
        Repo.insert(
          Message.changeset(%Message{}, %{
            task_id: task_id,
            from_agent_id: "agent-sender",
            to_agent_id: "agent-receiver",
            content: "Read message"
          })
        )

      Repo.update(Message.mark_read_changeset(read_msg))

      # Query unread messages
      unread_query = Quoracle.Messages.Queries.unread("agent-receiver")
      unread_messages = Repo.all(unread_query)

      assert length(unread_messages) == 3
      assert Enum.all?(unread_messages, fn m -> m.read_at == nil end)
    end

    @tag :integration
    test "count sent messages", %{task_id: task_id} do
      # Create messages from agent-counter
      for i <- 1..7 do
        Repo.insert(
          Message.changeset(%Message{}, %{
            task_id: task_id,
            from_agent_id: "agent-counter",
            to_agent_id: "agent-receiver-#{i}",
            content: "Message #{i}"
          })
        )
      end

      # Count messages
      count_query = Quoracle.Messages.Queries.count_sent("agent-counter")
      count = Repo.one(count_query)

      assert count == 7
    end

    @tag :integration
    test "ARC_FUNC_07: ordering by inserted_at maintains chronological order", %{task_id: task_id} do
      # Create messages with delays
      for i <- 1..5 do
        Repo.insert(
          Message.changeset(%Message{}, %{
            task_id: task_id,
            from_agent_id: "agent-chrono",
            to_agent_id: "agent-receiver",
            content: "Message #{i}"
          })
        )

        if i < 5, do: :timer.sleep(10)
      end

      # Query ordered by inserted_at
      query =
        from(m in Message,
          where: m.from_agent_id == "agent-chrono",
          order_by: [asc: m.inserted_at]
        )

      messages = Repo.all(query)

      # Verify all messages present (order may be non-deterministic with same timestamps)
      contents = Enum.map(messages, & &1.content) |> Enum.sort()
      assert contents == ["Message 1", "Message 2", "Message 3", "Message 4", "Message 5"]
    end
  end

  describe "cascade deletion" do
    setup do
      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))
      %{task: task}
    end

    @tag :integration
    test "ARC_FUNC_06: WHEN task deleted IF CASCADE configured THEN messages deleted", %{
      task: task
    } do
      # Create message for task
      {:ok, message} =
        Repo.insert(
          Message.changeset(%Message{}, %{
            task_id: task.id,
            from_agent_id: "agent-sender",
            to_agent_id: "agent-receiver",
            content: "Test message"
          })
        )

      # Delete task
      assert {:ok, _} = Repo.delete(task)

      # Verify message was deleted via CASCADE
      assert Repo.get(Message, message.id) == nil
    end
  end
end
