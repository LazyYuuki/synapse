defmodule Synapse.Workspace.OperationContext do
  @moduledoc """
  Caller-owned authority and lifetime context consumed by Workspace operations.

  The context lets Runtime or another trusted caller propagate operation identity, reduced access,
  cancellation, deadlines, and activity without Workspace importing Runtime.
  `deadline` is an absolute `System.monotonic_time(:millisecond)` value or
  `:infinity`. A matching `{:cancel, cancel_ref}` message is sent to the process
  currently executing the Workspace operation. File mutations are non-cancellable
  after MutationServer admission in the MVP. Reads and process admission honor
  matching cancellation; an accepted process is stopped with bounded cleanup.
  """

  alias Synapse.Workspace.{Access, Limits, Validation}

  @enforce_keys [:operation_id, :access]
  defstruct operation_id: nil,
            access: nil,
            cancel_ref: nil,
            deadline: :infinity,
            activity_sink: nil

  @typedoc "Synchronous meaningful-activity notification accepted only with `:ok`."
  @type activity_sink :: (t() -> :ok)

  @typedoc "Operation-scoped authority and request-lifetime controls."
  @type t :: %__MODULE__{
          operation_id: String.t(),
          access: Access.t(),
          cancel_ref: reference() | nil,
          deadline: integer() | :infinity,
          activity_sink: activity_sink() | nil
        }

  @typedoc "A validation failure identifying the invalid operation-context field."
  @type validation_error ::
          {:attributes, :must_be_keyword_or_map}
          | {:unknown_fields, [term()]}
          | {:operation_id, :must_be_bounded_non_empty_string}
          | {:access, :must_be_workspace_access}
          | {:cancel_ref, :must_be_reference_or_nil}
          | {:deadline, :must_be_monotonic_time_or_infinity}
          | {:activity_sink, :must_be_arity_one_function_or_nil}

  @doc "Validates caller-owned operation data without starting timers or processes."
  @spec new(keyword() | map(), Limits.t()) :: {:ok, t()} | {:error, validation_error()}
  def new(attrs, limits \\ Limits.default()) do
    allowed = [:operation_id, :access, :cancel_ref, :deadline, :activity_sink]

    with {:ok, attrs} <- Validation.attributes(attrs, allowed),
         true <-
           Validation.bounded_string?(attrs[:operation_id], limits.max_operation_id_bytes, false) or
             {:error, {:operation_id, :must_be_bounded_non_empty_string}},
         {:ok, access} <- normalize_access(attrs[:access]),
         true <-
           is_nil(attrs[:cancel_ref]) or is_reference(attrs[:cancel_ref]) or
             {:error, {:cancel_ref, :must_be_reference_or_nil}},
         true <-
           Map.get(attrs, :deadline, :infinity) == :infinity or
             Validation.int64?(Map.get(attrs, :deadline, :infinity)) or
             {:error, {:deadline, :must_be_monotonic_time_or_infinity}},
         true <-
           is_nil(attrs[:activity_sink]) or is_function(attrs[:activity_sink], 1) or
             {:error, {:activity_sink, :must_be_arity_one_function_or_nil}} do
      {:ok,
       struct!(__MODULE__,
         operation_id: attrs.operation_id,
         access: access,
         cancel_ref: Map.get(attrs, :cancel_ref),
         deadline: Map.get(attrs, :deadline, :infinity),
         activity_sink: Map.get(attrs, :activity_sink)
       )}
    end
  end

  defp normalize_access(%Access{} = access) do
    case Access.new(Map.from_struct(access)) do
      {:ok, access} -> {:ok, access}
      {:error, _reason} -> {:error, {:access, :must_be_workspace_access}}
    end
  end

  defp normalize_access(_access), do: {:error, {:access, :must_be_workspace_access}}
end
