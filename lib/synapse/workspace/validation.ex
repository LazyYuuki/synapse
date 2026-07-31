# Internal contract validation helpers; not a stable Workspace API.
defmodule Synapse.Workspace.Validation do
  @moduledoc false

  @int64_min -9_223_372_036_854_775_808
  @int64_max 9_223_372_036_854_775_807

  @spec attributes(keyword() | map(), [atom()]) ::
          {:ok, map()}
          | {:error, {:attributes, :must_be_keyword_or_map} | {:unknown_fields, [term()]}}
  def attributes(attrs, allowed) when is_list(attrs) do
    if bounded_proper_list?(attrs, length(allowed) + 1) and Keyword.keyword?(attrs),
      do: attributes(Map.new(attrs), allowed),
      else: {:error, {:attributes, :must_be_keyword_or_map}}
  end

  def attributes(attrs, allowed) when is_map(attrs) do
    if map_size(attrs) > length(allowed) + 1 do
      {:error, {:unknown_fields, [:too_many]}}
    else
      unknown = attrs |> Map.keys() |> Kernel.--(allowed) |> Enum.map(&safe_unknown_field/1)
      if unknown == [], do: {:ok, attrs}, else: {:error, {:unknown_fields, unknown}}
    end
  end

  def attributes(_attrs, _allowed), do: {:error, {:attributes, :must_be_keyword_or_map}}

  defp safe_unknown_field(field) when is_atom(field) do
    if field |> Atom.to_string() |> byte_size() <= 128, do: field, else: :unknown
  end

  defp safe_unknown_field(_field), do: :unknown

  @spec bounded_string?(term(), pos_integer(), boolean()) :: boolean()
  def bounded_string?(value, maximum, allow_empty? \\ true) do
    is_binary(value) and String.valid?(value) and byte_size(value) <= maximum and
      (allow_empty? or value != "")
  end

  @spec relative_path?(term(), pos_integer(), keyword()) :: boolean()
  def relative_path?(value, maximum, options \\ []) do
    allow_dot? = Keyword.get(options, :allow_dot, false)

    bounded_string?(value, maximum, false) and safe_path_bytes?(value) and
      Path.type(value) == :relative and valid_components?(value, allow_dot?)
  end

  @spec bounded_proper_list?(term(), non_neg_integer()) :: boolean()
  def bounded_proper_list?(value, maximum), do: bounded_proper_list?(value, maximum, 0)

  @spec int64?(term()) :: boolean()
  def int64?(value), do: is_integer(value) and value >= @int64_min and value <= @int64_max

  @spec positive_int64?(term()) :: boolean()
  def positive_int64?(value), do: int64?(value) and value > 0

  @spec non_negative_int64?(term()) :: boolean()
  def non_negative_int64?(value), do: int64?(value) and value >= 0

  @spec bounded_json_object?(term(), pos_integer(), non_neg_integer(), non_neg_integer()) ::
          boolean()
  def bounded_json_object?(value, max_bytes, max_entries, max_depth) when is_map(value) do
    match?(
      {:ok, _bytes, _entries},
      json_size(value, 0, 0, 0, max_bytes, max_entries, max_depth)
    )
  end

  def bounded_json_object?(_value, _max_bytes, _max_entries, _max_depth), do: false

  defp bounded_proper_list?([], _maximum, _count), do: true
  defp bounded_proper_list?(_value, maximum, count) when count >= maximum, do: false

  defp bounded_proper_list?([_item | rest], maximum, count),
    do: bounded_proper_list?(rest, maximum, count + 1)

  defp bounded_proper_list?(_value, _maximum, _count), do: false

  defp valid_components?(".", true), do: true

  defp valid_components?(value, _allow_dot?) do
    value
    |> String.split("/", trim: false)
    |> Enum.all?(&(&1 not in ["", ".", ".."] and String.valid?(&1)))
  end

  defp safe_path_bytes?(value) do
    value
    |> :binary.bin_to_list()
    |> Enum.all?(&(&1 >= 32 and &1 != 127))
  end

  defp json_size(_value, _bytes, entries, depth, _max_bytes, max_entries, max_depth)
       when entries > max_entries or depth > max_depth,
       do: :too_large

  defp json_size(value, bytes, entries, _depth, max_bytes, _max_entries, _max_depth)
       when is_binary(value) do
    if String.valid?(value),
      do: add_bytes(bytes, json_string_bytes(value), entries, max_bytes),
      else: :too_large
  end

  defp json_size(value, bytes, entries, _depth, max_bytes, _max_entries, _max_depth)
       when is_integer(value) and value >= @int64_min and value <= @int64_max,
       do: add_bytes(bytes, byte_size(Integer.to_string(value)), entries, max_bytes)

  defp json_size(value, bytes, entries, _depth, max_bytes, _max_entries, _max_depth)
       when is_float(value) do
    encoded = :erlang.float_to_binary(value, [:compact])
    add_bytes(bytes, byte_size(encoded), entries, max_bytes)
  end

  defp json_size(value, bytes, entries, _depth, max_bytes, _max_entries, _max_depth)
       when is_boolean(value),
       do: add_bytes(bytes, 5, entries, max_bytes)

  defp json_size(nil, bytes, entries, _depth, max_bytes, _max_entries, _max_depth),
    do: add_bytes(bytes, 4, entries, max_bytes)

  defp json_size(value, bytes, entries, depth, max_bytes, max_entries, max_depth)
       when is_map(value) do
    if map_size(value) + entries <= max_entries do
      with {:ok, bytes, entries} <- add_bytes(bytes, 2, entries, max_bytes) do
        Enum.reduce_while(value, {:ok, bytes, entries}, fn
          {key, item}, {:ok, current_bytes, current_entries} when is_binary(key) ->
            with true <- String.valid?(key),
                 {:ok, current_bytes, current_entries} <-
                   add_bytes(
                     current_bytes,
                     json_string_bytes(key) + 2,
                     current_entries + 1,
                     max_bytes
                   ),
                 {:ok, current_bytes, current_entries} <-
                   json_size(
                     item,
                     current_bytes,
                     current_entries,
                     depth + 1,
                     max_bytes,
                     max_entries,
                     max_depth
                   ) do
              {:cont, {:ok, current_bytes, current_entries}}
            else
              _invalid -> {:halt, :too_large}
            end

          _entry, _current ->
            {:halt, :too_large}
        end)
      end
    else
      :too_large
    end
  end

  defp json_size(value, bytes, entries, depth, max_bytes, max_entries, max_depth)
       when is_list(value) do
    with true <- bounded_proper_list?(value, max_entries - entries + 1),
         {:ok, bytes, entries} <- add_bytes(bytes, 2, entries, max_bytes) do
      Enum.reduce_while(value, {:ok, bytes, entries}, fn item,
                                                         {:ok, current_bytes, current_entries} ->
        if current_entries >= max_entries do
          {:halt, :too_large}
        else
          case json_size(
                 item,
                 current_bytes + 1,
                 current_entries + 1,
                 depth + 1,
                 max_bytes,
                 max_entries,
                 max_depth
               ) do
            {:ok, current_bytes, current_entries} ->
              if current_bytes <= max_bytes,
                do: {:cont, {:ok, current_bytes, current_entries}},
                else: {:halt, :too_large}

            :too_large ->
              {:halt, :too_large}
          end
        end
      end)
    else
      _invalid -> :too_large
    end
  end

  defp json_size(_value, _bytes, _entries, _depth, _max_bytes, _max_entries, _max_depth),
    do: :too_large

  defp add_bytes(bytes, addition, entries, maximum) when bytes + addition <= maximum,
    do: {:ok, bytes + addition, entries}

  defp add_bytes(_bytes, _addition, _entries, _maximum), do: :too_large

  defp json_string_bytes(value) do
    value
    |> :binary.bin_to_list()
    |> Enum.reduce(2, fn
      byte, total when byte in [?", ?\\] -> total + 2
      byte, total when byte < 32 -> total + 6
      _byte, total -> total + 1
    end)
  end
end
