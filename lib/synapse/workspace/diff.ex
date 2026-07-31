# Internal bounded unified-style whole-file diff summary.
defmodule Synapse.Workspace.Diff do
  @moduledoc false

  @spec build(binary(), binary(), String.t(), pos_integer(), :missing | :existing) ::
          {String.t(), boolean()}
  def build(old_content, new_content, path, maximum, previous) do
    old_path = if previous == :missing, do: "/dev/null", else: "a/#{path}"
    old_count = line_count(old_content)
    new_count = line_count(new_content)

    state =
      {[], 0, maximum, false}
      |> append("--- ")
      |> append(old_path)
      |> append("\n+++ b/")
      |> append(path)
      |> append("\n@@ -")
      |> append(hunk_range(old_count))
      |> append(" +")
      |> append(hunk_range(new_count))
      |> append(" @@\n")
      |> append_content("-", old_content)
      |> append_content("+", new_content)

    {parts, _bytes, _maximum, truncated?} = state
    diff = parts |> Enum.reverse() |> IO.iodata_to_binary()
    {if(truncated?, do: utf8_prefix(diff, byte_size(diff)), else: diff), truncated?}
  end

  defp line_count(""), do: 0

  defp line_count(content) do
    newline_count = count_newlines(content, 0)
    newline_count + if(String.ends_with?(content, "\n"), do: 0, else: 1)
  end

  defp count_newlines(content, count) do
    case :binary.match(content, "\n") do
      {index, 1} ->
        rest_start = index + 1
        rest = binary_part(content, rest_start, byte_size(content) - rest_start)
        count_newlines(rest, count + 1)

      :nomatch ->
        count
    end
  end

  defp hunk_range(0), do: "0,0"
  defp hunk_range(count), do: "1,#{count}"

  defp append({parts, bytes, maximum, true}, _segment),
    do: {parts, bytes, maximum, true}

  defp append({parts, bytes, maximum, false}, segment) do
    available = maximum - bytes

    if byte_size(segment) <= available do
      {[segment | parts], bytes + byte_size(segment), maximum, false}
    else
      prefix = if available == 0, do: "", else: binary_part(segment, 0, available)
      {[prefix | parts], maximum, maximum, true}
    end
  end

  defp append_content(state, _prefix, ""), do: state

  defp append_content({_parts, _bytes, _maximum, true} = state, _prefix, _content), do: state

  defp append_content(state, prefix, content) do
    case :binary.match(content, "\n") do
      {index, 1} ->
        line_bytes = index + 1
        line = binary_part(content, 0, line_bytes)
        rest = binary_part(content, line_bytes, byte_size(content) - line_bytes)

        state
        |> append(prefix)
        |> append(line)
        |> append_content(prefix, rest)

      :nomatch ->
        state
        |> append(prefix)
        |> append(content)
        |> append("\n\\ No newline at end of file\n")
    end
  end

  defp utf8_prefix(content, maximum) do
    candidate = binary_part(content, 0, maximum)
    trim_invalid_suffix(candidate, min(3, byte_size(candidate)))
  end

  defp trim_invalid_suffix(candidate, remaining) do
    cond do
      String.valid?(candidate) ->
        :binary.copy(candidate)

      remaining == 0 ->
        ""

      true ->
        trim_invalid_suffix(binary_part(candidate, 0, byte_size(candidate) - 1), remaining - 1)
    end
  end
end
