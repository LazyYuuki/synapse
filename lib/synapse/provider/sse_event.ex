defmodule Synapse.Provider.SSEEvent do
  @moduledoc """
  A protocol-neutral Server-Sent Events frame.

  `Synapse.Provider.SSEDecoder` creates frames from arbitrary HTTP body chunks.
  `Synapse.Provider.ResponsesStream` consumes them and interprets `data` as
  Responses JSON. This struct itself has no JSON or provider-event knowledge.

  Fields:

  * `event` is the explicit SSE event name, or `nil` when none was supplied.
  * `data` joins all `data` fields with newline bytes according to SSE rules.
  * `id` is the optional ID field from this frame.
  * `retry` is a valid non-negative retry value from this frame, in milliseconds;
    the MVP transport deliberately ignores this hint because Provider does not
    execute retries.
  * `unknown_fields` preserves unrecognized binary field/value pairs in order.

  Comments are transport activity rather than event data and are not retained in
  this struct.
  """

  @enforce_keys [:data]
  defstruct event: nil, data: nil, id: nil, retry: nil, unknown_fields: []

  @typedoc "A complete SSE frame produced by SSEDecoder and consumed by ResponsesStream."
  @type t :: %__MODULE__{
          event: binary() | nil,
          data: binary(),
          id: binary() | nil,
          retry: non_neg_integer() | nil,
          unknown_fields: [{binary(), binary()}]
        }
end
