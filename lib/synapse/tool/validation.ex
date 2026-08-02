defmodule Synapse.Tool.Validation do
  @moduledoc false

  @int64_min -9_223_372_036_854_775_808
  @int64_max 9_223_372_036_854_775_807

  @unsafe_metadata_fragments ~w(
    absolute_path api_key arguments authorization body command content cookie credential diff
    environment exception handle lines new_text old_text output password port reference root secret
    stacktrace token
  )

  @spec attributes(keyword() | map(), [atom()]) ::
          {:ok, map()}
          | {:error, {:attributes, :must_be_keyword_or_map} | {:unknown_fields, [term()]}}
  def attributes(attrs, allowed) when is_list(attrs) do
    if proper_list?(attrs, length(allowed) + 1) and Keyword.keyword?(attrs),
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

  @spec identifier?(term(), pos_integer()) :: boolean()
  def identifier?(value, maximum) do
    is_binary(value) and byte_size(value) <= maximum and String.valid?(value) and
      String.trim(value) != "" and safe_identifier_bytes?(value)
  end

  @spec non_empty_string?(term()) :: boolean()
  def non_empty_string?(value),
    do: is_binary(value) and String.valid?(value) and String.trim(value) != ""

  @spec bounded_non_empty_string?(term(), pos_integer()) :: boolean()
  def bounded_non_empty_string?(value, maximum),
    do:
      is_binary(value) and byte_size(value) <= maximum and String.valid?(value) and
        String.trim(value) != ""

  @spec int64?(term()) :: boolean()
  def int64?(value), do: is_integer(value) and value >= @int64_min and value <= @int64_max

  @spec bounded_json_object?(term(), pos_integer(), non_neg_integer(), non_neg_integer()) ::
          boolean()
  def bounded_json_object?(value, max_bytes, max_entries, max_depth) when is_map(value) do
    not is_struct(value) and
      match?(
        {:ok, _bytes, _entries},
        json_size(value, 0, 0, max_bytes, max_entries, max_depth)
      )
  end

  def bounded_json_object?(_value, _max_bytes, _max_entries, _max_depth), do: false

  @spec safe_metadata_object?(term(), pos_integer(), non_neg_integer(), non_neg_integer()) ::
          boolean()
  def safe_metadata_object?(value, max_bytes, max_entries, max_depth) do
    bounded_json_object?(value, max_bytes, max_entries, max_depth) and safe_metadata_keys?(value)
  end

  @spec bounded_json_bytes(term(), pos_integer(), non_neg_integer(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | :error
  def bounded_json_bytes(value, max_bytes, max_entries, max_depth) do
    case json_size(value, 0, 0, max_bytes, max_entries, max_depth) do
      {:ok, bytes, _entries} -> {:ok, bytes}
      :error -> :error
    end
  end

  @spec decode_unique_object(binary()) :: {:ok, map()} | :error
  def decode_unique_object(content) when is_binary(content) do
    decoders = [
      object_start: fn _old_acc -> %{} end,
      object_push: fn key, value, object ->
        if Map.has_key?(object, key),
          do: throw(:duplicate_json_key),
          else: Map.put(object, key, value)
      end,
      object_finish: fn object, old_acc -> {object, old_acc} end
    ]

    case Elixir.JSON.decode(content, nil, decoders) do
      {value, nil, rest} when is_map(value) ->
        if String.trim(rest) == "", do: {:ok, value}, else: :error

      _invalid ->
        :error
    end
  rescue
    _exception -> :error
  catch
    _kind, _reason -> :error
  end

  def decode_unique_object(_content), do: :error

  @spec proper_list?(term(), non_neg_integer()) :: boolean()
  def proper_list?(value, maximum), do: proper_list?(value, maximum, 0)

  defp json_size(_value, _depth, entries, _max_bytes, max_entries, _max_depth)
       when entries > max_entries,
       do: :error

  defp json_size(value, _depth, entries, max_bytes, _max_entries, _max_depth)
       when is_binary(value) do
    if byte_size(value) + 2 <= max_bytes and String.valid?(value) do
      bytes = json_string_bytes(value)
      if bytes <= max_bytes, do: {:ok, bytes, entries}, else: :error
    else
      :error
    end
  end

  defp json_size(value, _depth, entries, max_bytes, _max_entries, _max_depth)
       when is_integer(value) do
    if int64?(value), do: scalar_size(Integer.to_string(value), entries, max_bytes), else: :error
  end

  defp json_size(value, _depth, entries, max_bytes, _max_entries, _max_depth)
       when is_float(value) do
    try do
      scalar_size(Elixir.JSON.encode!(value), entries, max_bytes)
    rescue
      _exception -> :error
    end
  end

  defp json_size(true, _depth, entries, max_bytes, _max_entries, _max_depth),
    do: scalar_size("true", entries, max_bytes)

  defp json_size(false, _depth, entries, max_bytes, _max_entries, _max_depth),
    do: scalar_size("false", entries, max_bytes)

  defp json_size(nil, _depth, entries, max_bytes, _max_entries, _max_depth),
    do: scalar_size("null", entries, max_bytes)

  defp json_size(value, depth, entries, max_bytes, max_entries, max_depth)
       when is_map(value) do
    cond do
      is_struct(value) or depth > max_depth or map_size(value) + entries > max_entries ->
        :error

      true ->
        base_bytes = 2 + max(map_size(value) - 1, 0)

        if base_bytes <= max_bytes do
          Enum.reduce_while(value, {:ok, base_bytes, entries + map_size(value)}, fn
            {key, item}, {:ok, current_bytes, current_entries} when is_binary(key) ->
              remaining = max_bytes - current_bytes

              with true <- byte_size(key) + 3 <= remaining and String.valid?(key),
                   key_bytes <- json_string_bytes(key) + 1,
                   true <- key_bytes <= remaining,
                   {:ok, item_bytes, next_entries} <-
                     json_size(
                       item,
                       nested_depth(item, depth),
                       current_entries,
                       remaining - key_bytes,
                       max_entries,
                       max_depth
                     ) do
                {:cont, {:ok, current_bytes + key_bytes + item_bytes, next_entries}}
              else
                _invalid -> {:halt, :error}
              end

            _entry, _current ->
              {:halt, :error}
          end)
        else
          :error
        end
    end
  end

  defp json_size(value, depth, entries, max_bytes, max_entries, max_depth)
       when is_list(value) do
    with true <- depth <= max_depth,
         {:ok, count} <- proper_list_count(value, max_entries - entries),
         base_bytes <- 2 + max(count - 1, 0),
         true <- base_bytes <= max_bytes do
      reduce_json_list(
        value,
        depth,
        entries + count,
        base_bytes,
        max_bytes,
        max_entries,
        max_depth
      )
    else
      _invalid -> :error
    end
  end

  defp json_size(_value, _depth, _entries, _max_bytes, _max_entries, _max_depth), do: :error

  defp reduce_json_list(
         [],
         _depth,
         entries,
         bytes,
         _max_bytes,
         _max_entries,
         _max_depth
       ),
       do: {:ok, bytes, entries}

  defp reduce_json_list(
         [item | rest],
         depth,
         entries,
         bytes,
         max_bytes,
         max_entries,
         max_depth
       ) do
    case json_size(
           item,
           nested_depth(item, depth),
           entries,
           max_bytes - bytes,
           max_entries,
           max_depth
         ) do
      {:ok, item_bytes, next_entries} ->
        reduce_json_list(
          rest,
          depth,
          next_entries,
          bytes + item_bytes,
          max_bytes,
          max_entries,
          max_depth
        )

      :error ->
        :error
    end
  end

  defp reduce_json_list(
         _improper,
         _depth,
         _entries,
         _bytes,
         _max_bytes,
         _max_entries,
         _max_depth
       ),
       do: :error

  defp nested_depth(value, depth) when is_map(value) or is_list(value), do: depth + 1
  defp nested_depth(_value, depth), do: depth

  defp safe_metadata_keys?(value) when is_map(value) do
    Enum.all?(value, fn {key, item} -> safe_metadata_key?(key) and safe_metadata_keys?(item) end)
  end

  defp safe_metadata_keys?(value) when is_list(value),
    do: proper_list?(value, 1_000_000) and Enum.all?(value, &safe_metadata_keys?/1)

  defp safe_metadata_keys?(_value), do: true

  defp safe_metadata_key?(key) do
    is_binary(key) and String.valid?(key) and safe_identifier_bytes?(key) and
      not Enum.any?(@unsafe_metadata_fragments, fn fragment ->
        key
        |> String.downcase()
        |> String.replace("-", "_")
        |> String.contains?(fragment)
      end)
  end

  defp safe_identifier_bytes?(value) do
    value
    |> :binary.bin_to_list()
    |> Enum.all?(&(&1 >= 32 and &1 != 127))
  end

  defp proper_list?([], _maximum, _count), do: true
  defp proper_list?(_value, maximum, count) when count >= maximum, do: false
  defp proper_list?([_item | rest], maximum, count), do: proper_list?(rest, maximum, count + 1)
  defp proper_list?(_value, _maximum, _count), do: false

  defp proper_list_count(value, maximum), do: proper_list_count(value, maximum, 0)
  defp proper_list_count([], _maximum, count), do: {:ok, count}
  defp proper_list_count(_value, maximum, count) when count >= maximum, do: :error

  defp proper_list_count([_item | rest], maximum, count),
    do: proper_list_count(rest, maximum, count + 1)

  defp proper_list_count(_value, _maximum, _count), do: :error

  defp scalar_size(encoded, entries, maximum) do
    bytes = byte_size(encoded)
    if bytes <= maximum, do: {:ok, bytes, entries}, else: :error
  end

  defp json_string_bytes(value), do: json_string_bytes(value, 2)
  defp json_string_bytes(<<>>, total), do: total

  defp json_string_bytes(<<byte, rest::binary>>, total) when byte in [8, 9, 10, 12, 13],
    do: json_string_bytes(rest, total + 2)

  defp json_string_bytes(<<byte, rest::binary>>, total) when byte < 32,
    do: json_string_bytes(rest, total + 6)

  defp json_string_bytes(<<byte, rest::binary>>, total) when byte in [?", ?\\],
    do: json_string_bytes(rest, total + 2)

  defp json_string_bytes(<<_byte, rest::binary>>, total),
    do: json_string_bytes(rest, total + 1)

  defp safe_unknown_field(field) when is_atom(field) do
    if field |> Atom.to_string() |> byte_size() <= 128, do: field, else: :unknown
  end

  defp safe_unknown_field(_field), do: :unknown
end
