defmodule Synapse.Provider.Credentials.Secret do
  @moduledoc """
  An opaque, inspection-redacted handle to one resolved credential.

  `Synapse.Provider.Credentials` creates this handle and controls temporary raw
  access through `Synapse.Provider.Credentials.with_value/2`. Callers must not
  construct it directly or retain it beyond one Provider HTTP operation.

  Its internal closure reduces accidental disclosure under expanded struct
  inspection, but deliberate code can still extract the closure environment.
  This type is a lifecycle and logging guard, not a secure memory container.
  """

  @enforce_keys [:accessor]
  defstruct [:accessor]

  @typedoc "An opaque, inspection-redacted credential handle scoped to one Provider operation."
  @opaque t :: %__MODULE__{accessor: (-> String.t())}
end

defimpl Inspect, for: Synapse.Provider.Credentials.Secret do
  def inspect(_secret, _options), do: "#Synapse.Provider.Credentials.Secret<redacted>"
end

defmodule Synapse.Provider.Credentials do
  @moduledoc """
  Resolves the Tokamak API key at the narrow Provider request boundary.

  The MVP adapter reads `TOKAMAK_API_KEY` from the process environment only when
  a Provider operation is about to construct its authorization header. It does
  not read credentials during module compilation, application startup, request
  contract construction, or Agent Loop state initialization.

  `resolve/2` accepts an injected lookup function so tests and a future local
  credential broker can supply a key without mutating global environment state.
  A keychain-backed broker can replace the default environment adapter without
  changing Provider requests, events, responses, or errors.

  ## Lifetime

      process environment
        -> resolve/1
        -> redacted Secret wrapper
        -> with_value/2 callback
        -> Authorization header owned by Tokamak transport
        -> request completes and references leave Provider execution

  The environment, the lookup function, the secret wrapper, the callback, the
  temporary header collection, and Req's request machinery can observe the raw
  value. The Agent Loop and shared Provider contracts cannot. Synapse does not
  accept the key as a CLI argument because command histories, process listings,
  shell expansion, and general run structs create broader disclosure paths.

  Custom inspection is defense in depth against accidental logs and IEx output;
  it is not proof of non-disclosure. Code inside `with_value/2` can deliberately
  return, persist, send, or log the value. BEAM binaries are immutable and this
  module cannot guarantee memory wiping after use. The transport must therefore
  keep the callback narrow and must not include headers in errors or diagnostics.
  """

  alias Synapse.Provider.Credentials.Secret
  alias Synapse.Provider.Error

  @environment_variable "TOKAMAK_API_KEY"

  @typedoc "A runtime lookup adapter, normally `System.get_env/1`."
  @type source :: (String.t() -> String.t() | nil)

  @doc "Resolves `TOKAMAK_API_KEY` from the process environment at request time."
  @spec resolve(String.t()) :: {:ok, Secret.t()} | {:error, Error.t()}
  def resolve(operation_id), do: resolve(operation_id, &System.get_env/1)

  @doc """
  Resolves the key through an injected source without changing global state.

  Missing, invalid UTF-8, empty, and whitespace-only values return the same
  sanitized configuration error. Leading and trailing whitespace is removed
  before the key enters its wrapper. An invalid operation ID raises
  `ArgumentError`; exceptions from an injected source propagate to the transport
  worker, which converts them to a sanitized exception-class error.
  """
  @spec resolve(String.t(), source()) :: {:ok, Secret.t()} | {:error, Error.t()}
  def resolve(operation_id, source)
      when is_binary(operation_id) and is_function(source, 1) do
    if String.valid?(operation_id) and String.trim(operation_id) != "" do
      case source.(@environment_variable) do
        value when is_binary(value) -> normalize(operation_id, value)
        _missing -> configuration_error(operation_id)
      end
    else
      raise ArgumentError, "operation_id must be a non-empty UTF-8 string"
    end
  end

  @doc """
  Gives a callback temporary access to the raw key and returns its result.

  Callers should construct and use the authorization header inside this callback
  rather than returning the raw value or retaining the wrapper beyond one HTTP
  operation. Callback exceptions propagate to the owning transport worker.
  """
  @spec with_value(Secret.t(), (String.t() -> result)) :: result when result: term()
  def with_value(%Secret{accessor: accessor}, callback) when is_function(callback, 1),
    do: callback.(accessor.())

  defp normalize(operation_id, value) do
    if String.valid?(value) do
      case String.trim(value) do
        "" -> configuration_error(operation_id)
        value -> {:ok, %Secret{accessor: fn -> value end}}
      end
    else
      configuration_error(operation_id)
    end
  end

  defp configuration_error(operation_id) do
    {:error,
     %Error{
       kind: :configuration,
       message: "Tokamak API key is not configured",
       retryable: false,
       output_started: false,
       operation_id: operation_id,
       details: %{"environment_variable" => @environment_variable}
     }}
  end
end
