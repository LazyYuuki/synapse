defmodule Synapse.Provider do
  @moduledoc """
  Defines the boundary between the Agent Loop and a model provider.

  The Agent Loop supplies a normalized `Synapse.Provider.Request` and consumes
  synchronous `Synapse.Provider.Event` values in emission order. A completed
  stream returns a `Synapse.Provider.Response`; a terminal failure returns a
  sanitized `Synapse.Provider.Error` instead.

  Implementations own transport and wire-protocol details. Callers must not need
  Tokamak endpoints, Req options, authorization headers, or raw response maps.
  The synchronous event sink intentionally applies backpressure: an
  implementation does not continue producing events until the sink returns.

  Explicit structs make ownership and valid fields visible in typespecs, ExDoc,
  and LSP hovers. They also prevent an unrelated map, such as a raw HTTP
  response, from silently crossing the Provider boundary.
  """

  alias Synapse.Provider.{Error, Event, Request, Response, StreamContext}

  @typedoc "A recursively valid JSON value; object keys are always strings."
  @type json_value ::
          nil | boolean() | number() | String.t() | [json_value()] | json_object()

  @typedoc "A string-keyed JSON object used by normalized Provider contracts."
  @type json_object :: %{optional(String.t()) => json_value()}

  @typedoc "A synchronous consumer for one normalized streaming event."
  @type event_sink :: (Event.t() -> :ok)

  @doc """
  Streams one request and returns its normalized terminal result.

  Events describe ordered progress and are not terminal results. Implementations
  return exactly one completed response or one structured error after event
  production stops.
  """
  @callback stream(Request.t(), event_sink(), StreamContext.t()) ::
              {:ok, Response.t()} | {:error, Error.t()}
end
