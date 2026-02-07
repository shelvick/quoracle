defmodule Quoracle.UI.RingBuffer do
  @moduledoc """
  Pure functional circular buffer with O(1) insert and FIFO eviction.
  Uses Erlang :queue for efficient double-ended operations.

  Items are stored in chronological order (oldest first when converted to list).
  When capacity is reached, the oldest item is evicted on each insert.
  """

  defstruct items: :queue.new(), size: 0, max_size: 100

  @type t :: %__MODULE__{
          items: :queue.queue(),
          size: non_neg_integer(),
          max_size: pos_integer()
        }

  @doc """
  Creates a new ring buffer with the specified maximum size.

  Raises `ArgumentError` if max_size is not a positive integer.
  """
  @spec new(pos_integer()) :: t()
  def new(max_size) when is_integer(max_size) and max_size > 0 do
    %__MODULE__{items: :queue.new(), size: 0, max_size: max_size}
  end

  def new(_max_size) do
    raise ArgumentError, "max_size must be a positive integer"
  end

  @doc """
  Inserts an item into the buffer.

  If the buffer is at capacity, the oldest item is evicted (FIFO).
  Returns a new buffer with the item added.
  """
  @spec insert(t(), term()) :: t()
  def insert(%__MODULE__{size: size, max_size: max_size} = buffer, item)
      when size < max_size do
    %{buffer | items: :queue.in(item, buffer.items), size: size + 1}
  end

  def insert(%__MODULE__{} = buffer, item) do
    # At capacity - dequeue oldest, enqueue new
    {_evicted, remaining} = :queue.out(buffer.items)
    %{buffer | items: :queue.in(item, remaining)}
  end

  @doc """
  Converts the buffer to a list with items in chronological order (oldest first).
  """
  @spec to_list(t()) :: [term()]
  def to_list(%__MODULE__{items: items}) do
    :queue.to_list(items)
  end

  @doc """
  Returns the current number of items in the buffer.
  """
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{size: size}) do
    size
  end

  @doc """
  Returns true if the buffer is empty.
  """
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{size: 0}), do: true
  def empty?(%__MODULE__{}), do: false

  @doc """
  Clears all items from the buffer, preserving the max_size.
  """
  @spec clear(t()) :: t()
  def clear(%__MODULE__{max_size: max_size}) do
    %__MODULE__{items: :queue.new(), size: 0, max_size: max_size}
  end
end
