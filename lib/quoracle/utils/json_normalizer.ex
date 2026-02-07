defmodule Quoracle.Utils.JSONNormalizer do
  @moduledoc """
  Normalizes Elixir data structures to pretty-printed JSON strings.

  Handles error tuples, PIDs, references, and other non-JSON-serializable types
  by converting them to human-readable string representations.
  """

  @doc """
  Normalizes any Elixir term to a pretty-printed JSON string.

  ## Examples

      iex> normalize(%{status: :ok, data: [1, 2, 3]})
      # Returns pretty-printed JSON

      iex> normalize({:ok, %{result: "success"}})
      # Returns JSON with type="ok" structure
  """
  @spec normalize(term()) :: String.t()
  def normalize(term) do
    term
    |> make_json_safe()
    |> Jason.encode!(pretty: true)
  end

  # Make various Elixir types safe for JSON encoding

  # Success tuples
  defp make_json_safe({:ok, value}) do
    %{"type" => "ok", "value" => make_json_safe(value)}
  end

  # Error tuples
  defp make_json_safe({:error, reason}) do
    %{"type" => "error", "reason" => make_json_safe(reason)}
  end

  # Generic 2-tuples (convert to map)
  defp make_json_safe({key, value}) when is_atom(key) do
    %{Atom.to_string(key) => make_json_safe(value)}
  end

  # Other tuples - convert to list
  defp make_json_safe(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&make_json_safe/1)
  end

  # Maps - convert atom keys to strings and recursively process values
  defp make_json_safe(map) when is_map(map) do
    # Handle structs by converting to map first
    map = if Map.has_key?(map, :__struct__), do: Map.from_struct(map), else: map

    Map.new(map, fn {key, value} ->
      # Convert any key type to string (atoms, refs, PIDs, etc.)
      string_key = key_to_string(key)
      {string_key, make_json_safe(value)}
    end)
  end

  # Lists - recursively process elements
  defp make_json_safe(list) when is_list(list) do
    # Check if it's a proper list
    if proper_list?(list) do
      Enum.map(list, &make_json_safe/1)
    else
      # Improper list - convert to proper list by collecting all elements
      improper_to_proper(list)
      |> Enum.map(&make_json_safe/1)
    end
  end

  # Binaries/strings - check for valid UTF-8
  defp make_json_safe(binary) when is_binary(binary) do
    if String.valid?(binary) do
      binary
    else
      # Invalid UTF-8 - convert to inspect representation
      inspect(binary)
    end
  end

  # Atoms - convert to strings
  defp make_json_safe(atom) when is_atom(atom) and not is_nil(atom) and not is_boolean(atom) do
    Atom.to_string(atom)
  end

  # PIDs - convert to string representation
  defp make_json_safe(pid) when is_pid(pid) do
    inspect(pid)
  end

  # References - convert to string representation
  defp make_json_safe(ref) when is_reference(ref) do
    inspect(ref)
  end

  # Functions - convert to string representation
  defp make_json_safe(fun) when is_function(fun) do
    inspect(fun)
  end

  # Ports - convert to string representation
  defp make_json_safe(port) when is_port(port) do
    inspect(port)
  end

  # Primitives (numbers, booleans, nil) - pass through
  defp make_json_safe(primitive) do
    primitive
  end

  # Helper: Convert any key type to string
  defp key_to_string(key) when is_atom(key), do: Atom.to_string(key)

  defp key_to_string(key) when is_binary(key) do
    if String.valid?(key), do: key, else: inspect(key)
  end

  defp key_to_string(key), do: inspect(key)

  # Helper: Check if list is proper (not improper)
  defp proper_list?([]), do: true
  defp proper_list?([_ | tail]) when is_list(tail), do: proper_list?(tail)
  defp proper_list?([_ | _]), do: false

  # Helper: Convert improper list to proper list
  defp improper_to_proper(list) do
    case list do
      [] -> []
      [head | tail] when is_list(tail) -> [head | improper_to_proper(tail)]
      [head | tail] -> [head, tail]
    end
  end
end
