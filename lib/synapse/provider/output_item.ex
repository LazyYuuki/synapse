defmodule Synapse.Provider.OutputItem do
  @moduledoc """
  Normalized completed output produced by a provider response.

  `Message` contains assistant-visible text. `FunctionCall` contains fully
  decoded arguments and is safe to consider for execution only after the
  Provider has returned a completed response. The Agent Loop consumes these
  items; transport maps never cross this boundary.
  """

  alias Synapse.Provider.OutputItem.{FunctionCall, Message}

  @typedoc "A completed assistant message or function call."
  @type t :: Message.t() | FunctionCall.t()
end

defmodule Synapse.Provider.OutputItem.Message do
  @moduledoc """
  A completed assistant text item.

  Fields identify the provider output item, its normalized assistant role, and
  its complete text content. `Synapse.Provider.ResponsesStream` creates this
  value and the Agent Loop stores or renders its content through higher layers.
  """

  @enforce_keys [:id, :role, :content]
  defstruct [:id, :role, :content]

  @typedoc "A complete assistant message created by a Provider and consumed by the Agent."
  @type t :: %__MODULE__{
          id: String.t(),
          role: :assistant,
          content: String.t()
        }
end

defmodule Synapse.Provider.OutputItem.FunctionCall do
  @moduledoc """
  A completed function call with decoded, string-keyed arguments.

  `id` identifies the provider output item while `call_id` pairs the call with a
  later function result. `name` selects a known tool. `arguments` is complete
  decoded JSON; partial argument fragments exist only in streaming events and
  must never be represented by this struct. `ResponsesStream` creates this only
  after argument validation; the Agent considers it only after successful
  terminal completion.
  """

  @enforce_keys [:id, :call_id, :name, :arguments]
  defstruct [:id, :call_id, :name, :arguments]

  @typedoc "A complete function call eligible for Agent consideration after terminal success."
  @type t :: %__MODULE__{
          id: String.t(),
          call_id: String.t(),
          name: String.t(),
          arguments: Synapse.Provider.json_object()
        }
end
