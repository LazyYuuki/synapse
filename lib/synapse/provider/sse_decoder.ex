defmodule Synapse.Provider.SSEDecoder.Error do
  @moduledoc """
  A structured, protocol-level SSE framing failure.

  The transport converts this error into a terminal `Synapse.Provider.Error`
  with operation context. Keeping framing errors independent lets the decoder
  remain pure and unaware of HTTP status, retries, or operation identifiers.

  `feed/2` and `finish/1` create this error. `reason` identifies an oversized
  chunk, line, or event, or incomplete EOF state; `limit` is the relevant
  configured ceiling and `actual` is the measured byte count.
  """

  @enforce_keys [:reason, :limit, :actual]
  defstruct [:reason, :limit, :actual]

  @typedoc "The framing invariant that was violated."
  @type reason ::
          :line_too_large
          | :chunk_too_large
          | :event_too_large
          | :incomplete_line
          | :incomplete_event

  @typedoc "A measured decoder failure consumed and normalized by transport."
  @type t :: %__MODULE__{
          reason: reason(),
          limit: pos_integer(),
          actual: non_neg_integer()
        }
end

defmodule Synapse.Provider.SSEDecoder do
  @default_max_line_bytes 65_536
  @default_max_event_data_bytes 1_048_576
  @default_max_chunk_bytes 2_097_152
  @maximum_max_line_bytes 1_048_576
  @maximum_max_event_data_bytes 8_388_608
  @maximum_max_chunk_bytes 8_388_608
  @maximum_retry_ms 2_147_483_647

  @moduledoc """
  Incrementally frames Server-Sent Events from arbitrary binary chunks.

  HTTP or TCP chunks are only transport deliveries. A chunk may contain part of
  a line, many lines, part of an SSE frame, or several frames. `feed/2` therefore
  buffers incomplete lines and emits an `SSEEvent` only after a blank-line frame
  boundary. It never decodes JSON or recognizes provider event names;
  `Synapse.Provider.ResponsesStream` owns those responsibilities.

  The decoder is immutable pure data rather than a process. The HTTP operation
  owns its decoder state and passes each body chunk through `feed/2`, which makes
  byte-boundary behavior deterministic and independently testable.

  The layers remain distinct:

      HTTP chunks
        -> complete SSE lines
        -> blank-line-delimited SSE frames
        -> Responses JSON objects
        -> normalized Provider events

  This module owns only the first two transitions. `line_fragments` stores
  incomplete line pieces in reverse order so repeated small chunks do not copy
  the entire buffered line. Complete `data` fields remain separate until a frame
  boundary, where they are joined once. `activity_count` records completed field
  and comment lines without turning comments into events.

  ## Limits

  The default maximum line is #{@default_max_line_bytes} bytes, excluding the LF
  terminator. The default maximum accumulated frame fields are
  #{@default_max_event_data_bytes} bytes. The latter includes field names and
  values retained until the terminating blank line, which also bounds preserved
  unknown fields. One supplied transport chunk is limited to 2 MiB before line
  splitting to prevent a malicious adapter from allocating an unbounded segment
  list. Limits can be lowered or raised within hard configuration ceilings.

  EOF is successful only when no partial line or unterminated frame remains.
  Truncated data returns a structured decoder error and is never dispatched as a
  complete event.

  ## Example

      iex> decoder = Synapse.Provider.SSEDecoder.new()
      iex> {:ok, decoder, []} = Synapse.Provider.SSEDecoder.feed(decoder, "event: res")
      iex> {:ok, decoder, []} = Synapse.Provider.SSEDecoder.feed(decoder, "ponse.created\\ndata: {")
      iex> {:ok, decoder, [event]} = Synapse.Provider.SSEDecoder.feed(decoder, "}\\n\\n")
      iex> {event.event, event.data}
      {"response.created", "{}"}
      iex> {:ok, _decoder, []} = Synapse.Provider.SSEDecoder.finish(decoder)

  """

  alias Synapse.Provider.SSEEvent
  alias __MODULE__.Error

  defstruct line_fragments: [],
            line_bytes: 0,
            event: nil,
            data_lines: [],
            id: nil,
            retry: nil,
            unknown_fields: [],
            event_bytes: 0,
            event_pending: false,
            activity_count: 0,
            max_line_bytes: @default_max_line_bytes,
            max_event_data_bytes: @default_max_event_data_bytes,
            max_chunk_bytes: @default_max_chunk_bytes

  @typedoc """
  Opaque immutable framing state owned by one HTTP operation.

  Callers create it with `new/1` and pass returned versions to `feed/2` and
  `finish/1`; its parser fields and representation are not a construction API.
  """
  @opaque t :: %__MODULE__{
            line_fragments: [binary()],
            line_bytes: non_neg_integer(),
            event: binary() | nil,
            data_lines: [binary()],
            id: binary() | nil,
            retry: non_neg_integer() | nil,
            unknown_fields: [{binary(), binary()}],
            event_bytes: non_neg_integer(),
            event_pending: boolean(),
            activity_count: non_neg_integer(),
            max_line_bytes: pos_integer(),
            max_event_data_bytes: pos_integer(),
            max_chunk_bytes: pos_integer()
          }

  @typedoc "Decoder construction options."
  @type option ::
          {:max_line_bytes, pos_integer()}
          | {:max_event_data_bytes, pos_integer()}
          | {:max_chunk_bytes, pos_integer()}

  @typedoc "A successful incremental decode result with events in wire order."
  @type decode_result :: {:ok, t(), [SSEEvent.t()]} | {:error, Error.t()}

  @doc """
  Creates an empty decoder with validated byte limits.

  Invalid option names, non-positive values, line limits above 1 MiB, and event
  or chunk limits above 8 MiB raise `ArgumentError`. These ceilings prevent a
  mistaken trusted configuration from disabling parser memory bounds.
  """
  @spec new([option()]) :: t()
  def new(options \\ []) do
    options =
      Keyword.validate!(options,
        max_line_bytes: @default_max_line_bytes,
        max_event_data_bytes: @default_max_event_data_bytes,
        max_chunk_bytes: @default_max_chunk_bytes
      )

    validate_limit!(:max_line_bytes, options[:max_line_bytes])
    validate_limit!(:max_event_data_bytes, options[:max_event_data_bytes])
    validate_limit!(:max_chunk_bytes, options[:max_chunk_bytes])

    %__MODULE__{
      max_line_bytes: options[:max_line_bytes],
      max_event_data_bytes: options[:max_event_data_bytes],
      max_chunk_bytes: options[:max_chunk_bytes]
    }
  end

  @doc """
  Consumes an arbitrary binary chunk and returns every newly completed frame.

  A comment line is ignored as frame content but increments `activity_count`, as
  do recognized and unknown field lines. An HTTP owner can compare that counter
  before and after a feed when comments should count as transport activity.
  """
  @spec feed(t(), binary()) :: decode_result()
  def feed(%__MODULE__{} = state, chunk) when is_binary(chunk) do
    if byte_size(chunk) <= state.max_chunk_bytes do
      chunk
      |> :binary.split("\n", [:global])
      |> consume_segments(state, [])
    else
      {:error,
       %Error{
         reason: :chunk_too_large,
         limit: state.max_chunk_bytes,
         actual: byte_size(chunk)
       }}
    end
  end

  @doc """
  Validates that EOF occurred between frames.

  Events are never implicitly dispatched at EOF. A non-empty partial line or a
  frame without its blank-line terminator returns an error so downstream code
  cannot mistake truncation for successful completion.
  """
  @spec finish(t()) :: decode_result()
  def finish(%__MODULE__{line_bytes: line_bytes} = state) when line_bytes > 0 do
    {:error,
     %Error{
       reason: :incomplete_line,
       limit: state.max_line_bytes,
       actual: line_bytes
     }}
  end

  def finish(%__MODULE__{event_pending: true} = state) do
    {:error,
     %Error{
       reason: :incomplete_event,
       limit: state.max_event_data_bytes,
       actual: state.event_bytes
     }}
  end

  def finish(%__MODULE__{} = state), do: {:ok, state, []}

  defp consume_segments([last_segment], state, events) do
    case append_line_fragment(state, last_segment) do
      {:ok, state} -> {:ok, state, Enum.reverse(events)}
      {:error, error} -> {:error, error}
    end
  end

  defp consume_segments([segment | rest], state, events) do
    with {:ok, state} <- append_line_fragment(state, segment),
         {:ok, state, event} <- complete_line(state) do
      events = if is_nil(event), do: events, else: [event | events]
      consume_segments(rest, state, events)
    end
  end

  defp append_line_fragment(state, ""), do: {:ok, state}

  defp append_line_fragment(state, fragment) do
    line_bytes = state.line_bytes + byte_size(fragment)

    if line_bytes > state.max_line_bytes do
      {:error,
       %Error{
         reason: :line_too_large,
         limit: state.max_line_bytes,
         actual: line_bytes
       }}
    else
      {:ok,
       %{
         state
         | line_fragments: [fragment | state.line_fragments],
           line_bytes: line_bytes
       }}
    end
  end

  defp complete_line(state) do
    line =
      state.line_fragments |> Enum.reverse() |> IO.iodata_to_binary() |> trim_carriage_return()

    state = %{state | line_fragments: [], line_bytes: 0}
    process_line(state, line)
  end

  defp process_line(state, ""), do: dispatch_event(state)

  defp process_line(state, <<":", _comment::binary>>) do
    {:ok, %{state | activity_count: state.activity_count + 1}, nil}
  end

  defp process_line(state, line) do
    {field, value} = split_field(line)
    field_bytes = byte_size(field) + byte_size(value)

    with {:ok, state} <- reserve_event_bytes(state, field_bytes) do
      state = %{state | event_pending: true, activity_count: state.activity_count + 1}
      {:ok, apply_field(state, field, value), nil}
    end
  end

  defp dispatch_event(%__MODULE__{data_lines: []} = state),
    do: {:ok, reset_event(state), nil}

  defp dispatch_event(state) do
    event = %SSEEvent{
      event: state.event,
      data: state.data_lines |> Enum.reverse() |> Enum.join("\n"),
      id: state.id,
      retry: state.retry,
      unknown_fields: Enum.reverse(state.unknown_fields)
    }

    {:ok, reset_event(state), event}
  end

  defp apply_field(state, "event", ""), do: %{state | event: nil}
  defp apply_field(state, "event", value), do: %{state | event: value}
  defp apply_field(state, "data", value), do: %{state | data_lines: [value | state.data_lines]}

  defp apply_field(state, "id", value) do
    if :binary.match(value, <<0>>) == :nomatch, do: %{state | id: value}, else: state
  end

  defp apply_field(state, "retry", value) do
    if decimal?(value) and byte_size(value) <= 10 do
      retry = String.to_integer(value)
      if retry <= @maximum_retry_ms, do: %{state | retry: retry}, else: state
    else
      state
    end
  end

  defp apply_field(state, field, value) do
    %{state | unknown_fields: [{field, value} | state.unknown_fields]}
  end

  defp reserve_event_bytes(state, bytes) do
    event_bytes = state.event_bytes + bytes

    if event_bytes > state.max_event_data_bytes do
      {:error,
       %Error{
         reason: :event_too_large,
         limit: state.max_event_data_bytes,
         actual: event_bytes
       }}
    else
      {:ok, %{state | event_bytes: event_bytes}}
    end
  end

  defp reset_event(state) do
    %{
      state
      | event: nil,
        data_lines: [],
        id: nil,
        retry: nil,
        unknown_fields: [],
        event_bytes: 0,
        event_pending: false
    }
  end

  defp split_field(line) do
    case :binary.split(line, ":") do
      [field] -> {field, ""}
      [field, <<" ", value::binary>>] -> {field, value}
      [field, value] -> {field, value}
    end
  end

  defp trim_carriage_return(""), do: ""

  defp trim_carriage_return(line) do
    if :binary.last(line) == ?\r,
      do: binary_part(line, 0, byte_size(line) - 1),
      else: line
  end

  defp decimal?(""), do: false
  defp decimal?(value), do: decimal_bytes?(value)

  defp decimal_bytes?(<<>>), do: true
  defp decimal_bytes?(<<digit, rest::binary>>) when digit in ?0..?9, do: decimal_bytes?(rest)
  defp decimal_bytes?(_value), do: false

  defp validate_limit!(name, value) do
    maximum =
      case name do
        :max_line_bytes -> @maximum_max_line_bytes
        :max_event_data_bytes -> @maximum_max_event_data_bytes
        :max_chunk_bytes -> @maximum_max_chunk_bytes
      end

    unless is_integer(value) and value > 0 and value <= maximum do
      raise ArgumentError,
            "#{name} must be a positive integer no greater than #{maximum}"
    end
  end
end
