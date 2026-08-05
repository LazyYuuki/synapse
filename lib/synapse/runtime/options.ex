defmodule Synapse.Runtime.Options do
  @moduledoc """
  Validated trusted configuration for one Runtime start.

  Options selects the concrete Provider, fixed instructions, compatible
  Workspace and Tool ceilings, an optional earlier absolute monotonic deadline,
  Agent retry-delay policy, and the Workspace opener boundary. It contains no Run
  Request, prompt, cwd, capability set, event sink, cancellation reference,
  credential, endpoint, transport adapter, or opened Handle.

  The Workspace opener is a trusted deterministic seam. Production uses
  `Synapse.Workspace.open/1`; tests may supply an arity-one callback that receives
  the already validated `Synapse.Workspace.OpenRequest` and opens a Fake backend
  under its exact owner, limits, and Access. Construction validates callback
  arity but never invokes Provider, retry policy, or Workspace opener.

  ## Example

      iex> {:ok, options} = Synapse.Runtime.Options.new(provider: Synapse.Provider.Fake)
      iex> {options.provider, options.deadline}
      {Synapse.Provider.Fake, :infinity}
  """

  alias Synapse.Tool.{Limits, Validation}
  alias Synapse.Workspace
  alias Synapse.Workspace.Limits, as: WorkspaceLimits
  alias Synapse.Workspace.{Handle, OpenRequest}

  @default_instructions "You are the Synapse coding agent."
  @max_instructions_bytes 65_536
  @required_operation_id_bytes 85
  @allowed_fields [
    :provider,
    :instructions,
    :workspace_limits,
    :tool_limits,
    :deadline,
    :retry_delay,
    :workspace_opener
  ]

  @enforce_keys @allowed_fields
  defstruct @allowed_fields

  @typedoc "A trusted callback opening one already validated Workspace request."
  @type workspace_opener ::
          (OpenRequest.t() -> {:ok, Handle.t()} | {:error, term()})

  @typedoc "A pure one-based retry ordinal to bounded-delay callback."
  @type retry_delay :: (pos_integer() -> non_neg_integer())

  @typedoc "Trusted Provider, Workspace, Tool, deadline, and retry policy."
  @type t :: %__MODULE__{
          provider: module(),
          instructions: String.t(),
          workspace_limits: WorkspaceLimits.t(),
          tool_limits: Limits.t(),
          deadline: integer() | :infinity,
          retry_delay: retry_delay(),
          workspace_opener: workspace_opener()
        }

  @typedoc "A field-specific invalid Runtime option."
  @type validation_error ::
          {:attributes, :must_be_keyword_or_map}
          | {:unknown_fields, [term()]}
          | {:provider, :must_implement_provider_behaviour}
          | {:instructions, :must_be_bounded_utf8_string}
          | {:workspace_limits, :must_be_workspace_limits}
          | {:tool_limits, :must_be_tool_limits}
          | {:tool_limits, :must_fit_workspace_and_agent_operation_ids}
          | {:deadline, :must_be_monotonic_time_or_infinity}
          | {:retry_delay, :must_be_arity_one_function}
          | {:workspace_opener, :must_be_arity_one_function}

  @doc "Validates trusted options without invoking callbacks or starting resources."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, validation_error()}
  def new(attrs \\ %{}) do
    with {:ok, attrs} <- Validation.attributes(attrs, @allowed_fields),
         provider <- Map.get(attrs, :provider, Synapse.Provider.Tokamak),
         true <-
           provider?(provider) or
             {:error, {:provider, :must_implement_provider_behaviour}},
         instructions <- Map.get(attrs, :instructions, @default_instructions),
         true <-
           bounded_instructions?(instructions) or
             {:error, {:instructions, :must_be_bounded_utf8_string}},
         {:ok, workspace_limits} <-
           normalize_workspace_limits(
             Map.get(attrs, :workspace_limits, WorkspaceLimits.default())
           ),
         {:ok, tool_limits} <-
           normalize_tool_limits(Map.get(attrs, :tool_limits, Limits.default())),
         true <-
           compatible_limits?(tool_limits, workspace_limits) or
             {:error, {:tool_limits, :must_fit_workspace_and_agent_operation_ids}},
         deadline <- Map.get(attrs, :deadline, :infinity),
         true <-
           deadline == :infinity or Validation.int64?(deadline) or
             {:error, {:deadline, :must_be_monotonic_time_or_infinity}},
         retry_delay <- Map.get(attrs, :retry_delay, &default_retry_delay/1),
         true <-
           is_function(retry_delay, 1) or
             {:error, {:retry_delay, :must_be_arity_one_function}},
         workspace_opener <- Map.get(attrs, :workspace_opener, &Workspace.open/1),
         true <-
           is_function(workspace_opener, 1) or
             {:error, {:workspace_opener, :must_be_arity_one_function}} do
      {:ok,
       %__MODULE__{
         provider: provider,
         instructions: instructions,
         workspace_limits: workspace_limits,
         tool_limits: tool_limits,
         deadline: deadline,
         retry_delay: retry_delay,
         workspace_opener: workspace_opener
       }}
    end
  end

  @doc "Returns whether an Options struct passes complete normalization."
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = options),
    do: match?({:ok, %__MODULE__{}}, new(Map.from_struct(options)))

  def valid?(_options), do: false

  defp provider?(provider) when is_atom(provider) do
    try do
      case :code.is_loaded(provider) do
        false -> provider_beam_contract?(provider)
        {_file, _path} -> provider_loaded_contract?(provider)
      end
    rescue
      _exception -> false
    catch
      _kind, _reason -> false
    end
  end

  defp provider?(_provider), do: false

  defp provider_loaded_contract?(provider),
    do:
      function_exported?(provider, :stream, 3) and
        Synapse.Provider in provider_behaviours(provider.module_info(:attributes))

  defp provider_beam_contract?(provider) do
    case :code.which(provider) do
      path when is_list(path) ->
        case :beam_lib.chunks(path, [:attributes, :exports]) do
          {:ok, {^provider, chunks}} ->
            {:stream, 3} in Keyword.fetch!(chunks, :exports) and
              Synapse.Provider in provider_behaviours(Keyword.fetch!(chunks, :attributes))

          _invalid ->
            false
        end

      _missing ->
        false
    end
  end

  defp provider_behaviours(attributes) do
    attributes
    |> Keyword.get_values(:behaviour)
    |> List.flatten()
  end

  defp bounded_instructions?(instructions),
    do:
      is_binary(instructions) and byte_size(instructions) <= @max_instructions_bytes and
        String.valid?(instructions)

  defp normalize_workspace_limits(%WorkspaceLimits{} = limits) do
    case WorkspaceLimits.new(Map.from_struct(limits)) do
      {:ok, limits} -> {:ok, limits}
      {:error, _reason} -> {:error, {:workspace_limits, :must_be_workspace_limits}}
    end
  end

  defp normalize_workspace_limits(_limits),
    do: {:error, {:workspace_limits, :must_be_workspace_limits}}

  defp normalize_tool_limits(%Limits{} = limits) do
    case Limits.new(Map.from_struct(limits)) do
      {:ok, limits} -> {:ok, limits}
      {:error, _reason} -> {:error, {:tool_limits, :must_be_tool_limits}}
    end
  end

  defp normalize_tool_limits(_limits), do: {:error, {:tool_limits, :must_be_tool_limits}}

  defp compatible_limits?(tool_limits, workspace_limits),
    do:
      tool_limits.max_operation_id_bytes >= @required_operation_id_bytes and
        Limits.fits_workspace?(tool_limits, workspace_limits)

  defp default_retry_delay(1), do: 250
  defp default_retry_delay(_ordinal), do: 1_000
end

defimpl Inspect, for: Synapse.Runtime.Options do
  def inspect(_options, _inspect_options), do: "#Synapse.Runtime.Options<redacted>"
end
