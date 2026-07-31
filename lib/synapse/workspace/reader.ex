# Internal bounded descriptor observation and line-window implementation.
defmodule Synapse.Workspace.Reader do
  @moduledoc false

  alias Synapse.Workspace.{Limits, OperationContext, ReadLine, ReadRequest, Resolved}

  @chunk_bytes 65_536

  @enforce_keys [:stat, :digest, :content, :lines, :next_line, :file_bytes]
  defstruct [:stat, :digest, :content, :lines, :next_line, :file_bytes]

  @type t :: %__MODULE__{
          stat: File.Stat.t(),
          digest: binary(),
          content: binary(),
          lines: [ReadLine.t()],
          next_line: pos_integer() | nil,
          file_bytes: non_neg_integer()
        }

  @type reason ::
          :file_changed
          | :file_too_large
          | :invalid_utf8
          | :cancelled
          | :deadline_elapsed
          | :activity_sink_failed
          | :access_denied
          | :io

  @spec read(Resolved.t(), ReadRequest.t(), OperationContext.t(), Limits.t(), keyword()) ::
          {:ok, t()} | {:error, reason()}
  def read(%Resolved{} = resolved, request, context, limits, options \\ []) do
    before_post_stat = Keyword.get(options, :before_post_stat, fn -> :ok end)
    after_chunk = Keyword.get(options, :after_chunk, fn -> :ok end)

    with :ok <- interrupted?(context) do
      case File.open(resolved.absolute, [:read, :raw, :binary]) do
        {:ok, descriptor} ->
          try do
            observe(
              descriptor,
              resolved,
              request,
              context,
              limits,
              before_post_stat,
              after_chunk
            )
          after
            :file.close(descriptor)
          end

        {:error, :enoent} ->
          {:error, :file_changed}

        {:error, :eacces} ->
          {:error, :access_denied}

        {:error, :eperm} ->
          {:error, :access_denied}

        {:error, _reason} ->
          {:error, :io}
      end
    end
  end

  @spec fingerprint(File.Stat.t()) :: tuple()
  def fingerprint(%File.Stat{} = stat) do
    {
      stat.major_device,
      stat.minor_device,
      stat.inode,
      stat.type,
      stat.links,
      stat.size,
      stat.mode,
      stat.mtime,
      stat.ctime
    }
  end

  defp observe(
         descriptor,
         resolved,
         request,
         context,
         limits,
         before_post_stat,
         after_chunk
       ) do
    with {:ok, before_stat} <- descriptor_stat(descriptor),
         true <-
           fingerprint(before_stat) == fingerprint(resolved.stat) or
             {:error, :file_changed},
         true <- before_stat.size <= limits.max_file_bytes or {:error, :file_too_large},
         {:ok, content, digest} <-
           read_content(descriptor, limits.max_file_bytes, context, after_chunk),
         :ok <- before_post_stat.(),
         {:ok, after_stat} <- descriptor_stat(descriptor),
         true <-
           fingerprint(before_stat) == fingerprint(after_stat) or
             {:error, :file_changed},
         true <- byte_size(content) == after_stat.size or {:error, :file_changed},
         true <- String.valid?(content) or {:error, :invalid_utf8},
         :ok <- interrupted?(context),
         {:ok, lines, next_line} <- line_window(content, request, context),
         :ok <- interrupted?(context) do
      {:ok,
       %__MODULE__{
         stat: after_stat,
         digest: digest,
         content: content,
         lines: lines,
         next_line: next_line,
         file_bytes: byte_size(content)
       }}
    else
      false -> {:error, :io}
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :io}
    end
  rescue
    _exception -> {:error, :io}
  catch
    _kind, _reason -> {:error, :io}
  end

  defp descriptor_stat(descriptor) do
    case :file.read_file_info(descriptor, time: :universal) do
      {:ok, record} -> {:ok, File.Stat.from_record(record)}
      {:error, _reason} -> {:error, :io}
    end
  end

  defp read_content(descriptor, maximum, context, after_chunk) do
    read_content(
      descriptor,
      maximum,
      context,
      after_chunk,
      [],
      :crypto.hash_init(:sha256),
      0
    )
  end

  defp read_content(descriptor, maximum, context, after_chunk, chunks, hash, bytes) do
    with :ok <- interrupted?(context) do
      read_size = min(@chunk_bytes, maximum - bytes + 1)

      case :file.read(descriptor, read_size) do
        :eof ->
          {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary(), :crypto.hash_final(hash)}

        {:ok, data} when bytes + byte_size(data) <= maximum ->
          with :ok <- after_chunk.() do
            read_content(
              descriptor,
              maximum,
              context,
              after_chunk,
              [data | chunks],
              :crypto.hash_update(hash, data),
              bytes + byte_size(data)
            )
          else
            _invalid -> {:error, :io}
          end

        {:ok, _data} ->
          {:error, :file_too_large}

        {:error, _reason} ->
          {:error, :io}
      end
    end
  end

  defp line_window(content, request, context) do
    collect_lines(content, 1, request, context, [], 0, 0)
  end

  defp collect_lines(content, number, request, context, lines, count, used_bytes) do
    with :ok <- maybe_interrupted?(context, number) do
      cond do
        content == "" ->
          {:ok, Enum.reverse(lines), nil}

        number >= request.start_line and count >= request.line_count ->
          {:ok, Enum.reverse(lines), number}

        number >= request.start_line and used_bytes >= request.max_bytes ->
          {:ok, Enum.reverse(lines), number}

        true ->
          {text, ending, rest} = take_line(content)

          if number < request.start_line do
            collect_lines(rest, number + 1, request, context, lines, count, used_bytes)
          else
            add_line(text, ending, rest, number, request, context, lines, count, used_bytes)
          end
      end
    end
  end

  defp add_line(text, ending, rest, number, request, context, lines, count, used_bytes) do
    line_bytes = byte_size(text) + ending_bytes(ending)
    remaining = request.max_bytes - used_bytes

    cond do
      line_bytes <= remaining ->
        line = %ReadLine{
          number: number,
          text: :binary.copy(text),
          ending: ending,
          truncated: false
        }

        collect_lines(
          rest,
          number + 1,
          request,
          context,
          [line | lines],
          count + 1,
          used_bytes + line_bytes
        )

      true ->
        clipped = utf8_prefix(text, remaining)

        line = %ReadLine{
          number: number,
          text: :binary.copy(clipped),
          ending: ending,
          truncated: true
        }

        next_line = if ending == :none or rest == "", do: nil, else: number + 1
        {:ok, Enum.reverse([line | lines]), next_line}
    end
  end

  defp take_line(content) do
    case :binary.match(content, "\n") do
      {index, 1} ->
        raw_text = binary_part(content, 0, index)
        rest_offset = index + 1
        rest = binary_part(content, rest_offset, byte_size(content) - rest_offset)

        if byte_size(raw_text) > 0 and :binary.last(raw_text) == ?\r do
          {binary_part(raw_text, 0, byte_size(raw_text) - 1), :crlf, rest}
        else
          {raw_text, :lf, rest}
        end

      :nomatch ->
        {content, :none, ""}
    end
  end

  defp utf8_prefix(text, maximum) when byte_size(text) <= maximum, do: text
  defp utf8_prefix(_text, maximum) when maximum <= 0, do: ""

  defp utf8_prefix(text, maximum) do
    candidate = binary_part(text, 0, maximum)
    trim_invalid_suffix(candidate, min(3, byte_size(candidate)))
  end

  defp trim_invalid_suffix(candidate, remaining) do
    cond do
      String.valid?(candidate) ->
        candidate

      remaining == 0 ->
        ""

      true ->
        trim_invalid_suffix(binary_part(candidate, 0, byte_size(candidate) - 1), remaining - 1)
    end
  end

  defp ending_bytes(:lf), do: 1
  defp ending_bytes(:crlf), do: 2
  defp ending_bytes(:none), do: 0

  defp maybe_interrupted?(context, line_number) when rem(line_number, 128) == 0,
    do: interrupted?(context)

  defp maybe_interrupted?(_context, _line_number), do: :ok

  defp interrupted?(context) do
    cond do
      deadline_elapsed?(context.deadline) -> {:error, :deadline_elapsed}
      cancelled?(context.cancel_ref) -> {:error, :cancelled}
      true -> :ok
    end
  end

  defp deadline_elapsed?(:infinity), do: false
  defp deadline_elapsed?(deadline), do: System.monotonic_time(:millisecond) >= deadline

  defp cancelled?(nil), do: false

  defp cancelled?(cancel_ref) do
    receive do
      {:cancel, ^cancel_ref} -> true
    after
      0 -> false
    end
  end

  @spec complete(OperationContext.t()) :: :ok | {:error, reason()}
  def complete(context) do
    with :ok <- interrupted?(context),
         :ok <- notify_activity(context) do
      :ok
    end
  end

  defp notify_activity(%OperationContext{activity_sink: nil}), do: :ok

  defp notify_activity(%OperationContext{activity_sink: sink} = context) do
    case sink.(context) do
      :ok -> :ok
      _invalid -> {:error, :activity_sink_failed}
    end
  rescue
    _exception -> {:error, :activity_sink_failed}
  catch
    _kind, _reason -> {:error, :activity_sink_failed}
  end
end
