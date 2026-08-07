defmodule Synapse.Provider.Event do
  @moduledoc """
  Ordered, normalized progress emitted while a provider request streams.

  The Provider creates events and synchronously sends them to the Agent Loop.
  Events allow incremental progress adaptation and tool-call accumulation, but they do not
  indicate terminal success by themselves. A completed `Synapse.Provider.Response`
  or terminal `Synapse.Provider.Error` remains authoritative.

  Tool-call delta events contain incomplete strings. Only `ToolCallCompleted`
  contains decoded arguments, and even that call is executable only after the
  overall provider response completes successfully.
  """

  alias Synapse.Provider.Event.{
    Diagnostic,
    MessageCompleted,
    MessageStarted,
    TextDelta,
    ToolCallCompleted,
    ToolCallDelta,
    ToolCallStarted
  }

  @typedoc "The closed union of normalized events emitted synchronously in stream order."
  @type t ::
          MessageStarted.t()
          | TextDelta.t()
          | ToolCallStarted.t()
          | ToolCallDelta.t()
          | ToolCallCompleted.t()
          | MessageCompleted.t()
          | Diagnostic.t()
end

defmodule Synapse.Provider.Event.MessageStarted do
  @moduledoc """
  Announces the normalized response identity before content events.

  `response_id` correlates subsequent activity and `model` records the model
  reported by the Provider. A Provider emits this after `response.created`; the
  Agent Loop consumes it before content events.
  """

  @enforce_keys [:response_id, :model]
  defstruct [:response_id, :model]

  @typedoc "The normalized response-start event created by a Provider."
  @type t :: %__MODULE__{response_id: String.t(), model: String.t()}
end

defmodule Synapse.Provider.Event.TextDelta do
  @moduledoc """
  Carries one ordered fragment of assistant text.

  `item_id` identifies the output item, `content_index` identifies its content
  part, and `delta` is the text fragment to append. The Provider emits fragments
  in source order; consumers append them without reordering.
  """

  @enforce_keys [:item_id, :content_index, :delta]
  defstruct [:item_id, :content_index, :delta]

  @typedoc "An append-only assistant text fragment emitted by a Provider."
  @type t :: %__MODULE__{
          item_id: String.t(),
          content_index: non_neg_integer(),
          delta: String.t()
        }
end

defmodule Synapse.Provider.Event.ToolCallStarted do
  @moduledoc """
  Announces a function-call item before its arguments are complete.

  `item_id` identifies provider output, `call_id` pairs the future result, and
  `name` identifies the requested tool. The Agent may create an accumulator for
  it, but this event is never executable.
  """

  @enforce_keys [:item_id, :call_id, :name]
  defstruct [:item_id, :call_id, :name]

  @typedoc "A non-executable function-call start emitted by a Provider."
  @type t :: %__MODULE__{item_id: String.t(), call_id: String.t(), name: String.t()}
end

defmodule Synapse.Provider.Event.ToolCallDelta do
  @moduledoc """
  Carries an incomplete JSON argument fragment for one function call.

  `item_id` and `call_id` select the accumulator; `delta` is appended verbatim.
  The Provider emits it and the Agent appends it to the matching accumulator.
  Callers must not decode or execute this partial value.
  """

  @enforce_keys [:item_id, :call_id, :delta]
  defstruct [:item_id, :call_id, :delta]

  @typedoc "An incomplete function-argument fragment emitted by a Provider."
  @type t :: %__MODULE__{item_id: String.t(), call_id: String.t(), delta: String.t()}
end

defmodule Synapse.Provider.Event.ToolCallCompleted do
  @moduledoc """
  Reports successfully decoded, complete function-call arguments.

  Completion makes the arguments structurally complete, but execution must wait
  for successful completion of the overall provider response. This prevents a
  later stream failure or truncation from executing an invalid call.

  `item_id` identifies normalized output, `call_id` pairs a later tool result,
  `name` selects the tool, and `arguments` is the decoded string-keyed JSON
  object. The Agent stages this event until `stream/3` returns a successful
  response containing the matching call:

      iex> event = %Synapse.Provider.Event.ToolCallCompleted{
      ...>   item_id: "item-1",
      ...>   call_id: "call-1",
      ...>   name: "read",
      ...>   arguments: %{"path" => "mix.exs"}
      ...> }
      iex> {:ok, response} = Synapse.Provider.Response.new(
      ...>   id: "response-1",
      ...>   model: "test-model",
      ...>   output_items: [
      ...>     %Synapse.Provider.OutputItem.FunctionCall{
      ...>       id: event.item_id,
      ...>       call_id: event.call_id,
      ...>       name: event.name,
      ...>       arguments: event.arguments
      ...>     }
      ...>   ]
      ...> )
      iex> Enum.any?(response.output_items, &(&1.call_id == event.call_id))
      true
  """

  @enforce_keys [:item_id, :call_id, :name, :arguments]
  defstruct [:item_id, :call_id, :name, :arguments]

  @typedoc "A structurally complete call staged until successful terminal completion."
  @type t :: %__MODULE__{
          item_id: String.t(),
          call_id: String.t(),
          name: String.t(),
          arguments: Synapse.Provider.json_object()
        }
end

defmodule Synapse.Provider.Event.MessageCompleted do
  @moduledoc """
  Emits the completed normalized response at the end of successful streaming.

  The Provider's return value remains the authoritative terminal result; this
  event lets synchronous observers finish incremental progress handling first. The
  Provider creates it and the Agent consumes it before `stream/3` returns the same
  authoritative response.
  """

  alias Synapse.Provider.Response

  @enforce_keys [:response]
  defstruct [:response]

  @typedoc "The successful response-completion event emitted to synchronous observers."
  @type t :: %__MODULE__{response: Response.t()}
end

defmodule Synapse.Provider.Event.Diagnostic do
  @moduledoc """
  Carries bounded, sanitized, non-terminal compatibility information.

  `code` is a stable string classification, `message` is safe for diagnostics,
  and `details` contains string-keyed JSON data. Raw response bodies, headers,
  credentials, and arbitrary exceptions do not belong here. Provider producers
  enforce their documented limits; direct struct construction does not sanitize
  arbitrary values. Consumers may surface this event but must not treat it as a
  terminal result.
  """

  @enforce_keys [:code, :message]
  defstruct [:code, :message, details: %{}]

  @typedoc "Bounded compatibility information emitted by a Provider producer."
  @type t :: %__MODULE__{
          code: String.t(),
          message: String.t(),
          details: Synapse.Provider.json_object()
        }
end
