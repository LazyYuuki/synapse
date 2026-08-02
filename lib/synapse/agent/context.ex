defmodule Synapse.Agent.Context do
  @moduledoc """
  Trusted dependencies and lifetime controls for one Agent run.

  Runtime or a deterministic test harness creates Context independently of model
  input. It carries the concrete Provider implementation, an already-opened
  opaque Workspace Handle, fixed instructions, synchronous event and activity
  sinks, persistent cancellation observation, an optional earlier absolute
  deadline, Tool Limits, and bounded retry-delay policy.

  Construction validates shape and Tool/Workspace limit compatibility without
  calling Provider, opening Workspace, emitting an event, or starting a timer.
  The retry-delay callback is validated when Runner later consumes each returned
  value; it must return 0..10,000 milliseconds.

  Ordinary inspection redacts all authority, callbacks, instructions, and
  references.

  Fields:

  * `provider` is a trusted module declaring the `Synapse.Provider` behaviour;
  * `workspace` is the Runtime-opened opaque Handle;
  * `instructions` is fixed top-level Provider guidance, not model input;
  * `event_sink` synchronously consumes validated Run Events;
  * `cancel_ref` is passed to the currently active lower operation;
  * `cancelled?` persistently observes run cancellation outside the mailbox; a
    callback failure makes Runner fail closed as cancellation;
  * `deadline` is Runtime's optional earlier absolute monotonic deadline;
  * activity sinks preserve Provider and Tool callback shapes without Runtime imports;
  * `tool_limits` is trusted lowering compatible with Workspace ceilings;
  * `retry_delay` returns bounded delay for one-based retry ordinals.

  ## Example

      iex> {:ok, handle} = Synapse.Workspace.Fake.open([])
      iex> {:ok, context} = Synapse.Agent.Context.new(
      ...>   provider: Synapse.Provider.Fake,
      ...>   workspace: handle,
      ...>   event_sink: fn _event -> :ok end
      ...> )
      iex> context.provider
      Synapse.Provider.Fake
      iex> Synapse.Workspace.close(handle)
      :ok
  """

  alias Synapse.Tool.{CapabilitySet, Context, Limits, Validation}
  alias Synapse.Workspace.{Access, Handle}
  alias Synapse.Workspace.Limits, as: WorkspaceLimits

  @default_instructions "You are the Synapse coding agent."
  @max_instructions_bytes 65_536
  @required_operation_id_bytes 85
  @allowed_fields [
    :provider,
    :workspace,
    :instructions,
    :event_sink,
    :cancel_ref,
    :cancelled?,
    :deadline,
    :provider_activity_sink,
    :tool_activity_sink,
    :tool_limits,
    :retry_delay
  ]

  @enforce_keys [
    :provider,
    :workspace,
    :instructions,
    :event_sink,
    :cancelled?,
    :tool_limits,
    :retry_delay
  ]
  defstruct provider: nil,
            workspace: nil,
            instructions: nil,
            event_sink: nil,
            cancel_ref: nil,
            cancelled?: nil,
            deadline: :infinity,
            provider_activity_sink: nil,
            tool_activity_sink: nil,
            tool_limits: nil,
            retry_delay: nil

  @typedoc "A synchronous consumer of one validated Run Event."
  @type event_sink :: (Synapse.Run.Event.t() -> :ok)

  @typedoc "A persistent cancellation probe that remains true after message consumption."
  @type cancellation_probe :: (-> boolean())

  @typedoc "A pure one-based retry ordinal to bounded delay callback."
  @type retry_delay :: (pos_integer() -> non_neg_integer())

  @typedoc "A synchronous Provider activity callback using its exact StreamContext."
  @type provider_activity_sink :: (Synapse.Provider.StreamContext.t() -> :ok)

  @typedoc "Trusted run dependencies and operation-lifetime policy."
  @type t :: %__MODULE__{
          provider: module(),
          workspace: Handle.t(),
          instructions: String.t(),
          event_sink: event_sink(),
          cancel_ref: reference() | nil,
          cancelled?: cancellation_probe(),
          deadline: integer() | :infinity,
          provider_activity_sink: provider_activity_sink() | nil,
          tool_activity_sink: Synapse.Tool.Context.activity_sink() | nil,
          tool_limits: Limits.t(),
          retry_delay: retry_delay()
        }

  @typedoc "A field-specific invalid trusted Agent Context."
  @type validation_error ::
          {:attributes, :must_be_keyword_or_map}
          | {:unknown_fields, [term()]}
          | {:provider, :must_implement_provider_behaviour}
          | {:workspace, :must_be_workspace_handle}
          | {:instructions, :must_be_bounded_utf8_string}
          | {:event_sink, :must_be_arity_one_function}
          | {:cancel_ref, :must_be_reference_or_nil}
          | {:cancelled?, :must_be_arity_zero_function}
          | {:deadline, :must_be_monotonic_time_or_infinity}
          | {:provider_activity_sink, :must_be_arity_one_function_or_nil}
          | {:tool_activity_sink, :must_be_arity_one_function_or_nil}
          | {:tool_limits, :must_fit_workspace_and_agent_operation_ids}
          | {:retry_delay, :must_be_arity_one_function}

  @doc "Validates trusted dependencies without invoking Provider or Workspace."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, validation_error()}
  def new(attrs) do
    with {:ok, attrs} <- Validation.attributes(attrs, @allowed_fields),
         provider <- attrs[:provider],
         true <-
           provider?(provider) or
             {:error, {:provider, :must_implement_provider_behaviour}},
         workspace <- attrs[:workspace],
         true <- workspace?(workspace) or {:error, {:workspace, :must_be_workspace_handle}},
         instructions <- Map.get(attrs, :instructions, @default_instructions),
         true <-
           bounded_instructions?(instructions) or
             {:error, {:instructions, :must_be_bounded_utf8_string}},
         event_sink <- attrs[:event_sink],
         true <-
           is_function(event_sink, 1) or
             {:error, {:event_sink, :must_be_arity_one_function}},
         cancel_ref <- Map.get(attrs, :cancel_ref),
         true <-
           is_nil(cancel_ref) or is_reference(cancel_ref) or
             {:error, {:cancel_ref, :must_be_reference_or_nil}},
         cancelled? <- Map.get(attrs, :cancelled?, &not_cancelled/0),
         true <-
           is_function(cancelled?, 0) or
             {:error, {:cancelled?, :must_be_arity_zero_function}},
         deadline <- Map.get(attrs, :deadline, :infinity),
         true <-
           deadline == :infinity or Validation.int64?(deadline) or
             {:error, {:deadline, :must_be_monotonic_time_or_infinity}},
         provider_activity_sink <- Map.get(attrs, :provider_activity_sink),
         true <-
           optional_sink?(provider_activity_sink) or
             {:error, {:provider_activity_sink, :must_be_arity_one_function_or_nil}},
         tool_activity_sink <- Map.get(attrs, :tool_activity_sink),
         true <-
           optional_sink?(tool_activity_sink) or
             {:error, {:tool_activity_sink, :must_be_arity_one_function_or_nil}},
         tool_limits <- Map.get(attrs, :tool_limits, Limits.default()),
         true <-
           valid_workspace_limits?(workspace, tool_limits) or
             {:error, {:tool_limits, :must_fit_workspace_and_agent_operation_ids}},
         retry_delay <- Map.get(attrs, :retry_delay, &default_retry_delay/1),
         true <-
           is_function(retry_delay, 1) or
             {:error, {:retry_delay, :must_be_arity_one_function}} do
      {:ok,
       %__MODULE__{
         provider: provider,
         workspace: workspace,
         instructions: instructions,
         event_sink: event_sink,
         cancel_ref: cancel_ref,
         cancelled?: cancelled?,
         deadline: deadline,
         provider_activity_sink: provider_activity_sink,
         tool_activity_sink: tool_activity_sink,
         tool_limits: tool_limits,
         retry_delay: retry_delay
       }}
    end
  end

  @doc "Returns whether a Context struct passes complete structural validation."
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = context),
    do: match?({:ok, %__MODULE__{}}, new(Map.from_struct(context)))

  def valid?(_context), do: false

  defp provider?(provider) when is_atom(provider) do
    Code.ensure_loaded?(provider) and function_exported?(provider, :stream, 3) and
      Synapse.Provider in provider_behaviours(provider)
  end

  defp provider?(_provider), do: false

  defp provider_behaviours(provider) do
    provider.module_info(:attributes)
    |> Keyword.get_values(:behaviour)
    |> List.flatten()
  end

  defp bounded_instructions?(instructions),
    do:
      is_binary(instructions) and byte_size(instructions) <= @max_instructions_bytes and
        String.valid?(instructions)

  defp optional_sink?(nil), do: true
  defp optional_sink?(sink), do: is_function(sink, 1)

  defp workspace?(%Handle{
         backend: backend,
         state: state,
         token: token,
         limits: limits,
         access: access
       }) do
    is_atom(backend) and (is_pid(state) or is_reference(state)) and is_reference(token) and
      WorkspaceLimits.valid?(limits) and Access.valid?(access)
  end

  defp workspace?(_workspace), do: false

  defp valid_workspace_limits?(%Handle{} = workspace, %Limits{} = limits) do
    limits.max_operation_id_bytes >= @required_operation_id_bytes and
      with {:ok, capabilities} <-
             CapabilitySet.new(fs_read: false, fs_write: false, process_exec: false),
           {:ok, _context} <-
             Context.new(
               workspace: workspace,
               capabilities: capabilities,
               operation_id: "a",
               limits: limits
             ) do
        true
      else
        _invalid -> false
      end
  end

  defp valid_workspace_limits?(_workspace, _limits), do: false

  defp not_cancelled, do: false
  defp default_retry_delay(1), do: 250
  defp default_retry_delay(_ordinal), do: 1_000
end

defimpl Inspect, for: Synapse.Agent.Context do
  def inspect(_context, _options), do: "#Synapse.Agent.Context<redacted>"
end
