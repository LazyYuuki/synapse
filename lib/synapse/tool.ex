defmodule Synapse.Tool do
  @moduledoc """
  Defines the contract implemented by one model-facing Tool.

  Tool System sits between Agent and Workspace. Agent submits one complete
  validated `Synapse.Tool.Call` plus trusted `Synapse.Tool.Context`. A known Tool
  prepares one typed Workspace request without receiving a Workspace Handle.
  Executor retains authority, dispatches the exact registered Workspace operation,
  and asks the Tool to present the retained terminal outcome as one paired
  `Synapse.Tool.Result`. Expected invalid arguments, denial, Workspace failure,
  cancellation, and ambiguity are Result data rather than exception policy.

  Implementations must not parse Provider streams, mutate Agent conversation
  state, print terminal output, retry an operation, or access host files and
  processes directly. Executor owns static lookup, capability enforcement, the
  only Workspace dispatch path, callback crash handling, and result pairing
  validation.
  """

  @typedoc "A recursively JSON-encodable value with string-keyed objects."
  @type json_value ::
          nil | boolean() | number() | String.t() | [json_value()] | json_object()

  @typedoc "A string-keyed object used for decoded arguments and safe metadata."
  @type json_object :: %{optional(String.t()) => json_value()}

  @typedoc "One typed request accepted only for its statically registered Tool."
  @type workspace_request ::
          Synapse.Workspace.ReadRequest.t()
          | Synapse.Workspace.WriteRequest.t()
          | Synapse.Workspace.EditRequest.t()
          | Synapse.Workspace.ProcessSpec.t()

  @typedoc "One retained terminal Workspace success or structured failure."
  @type workspace_outcome ::
          {:ok,
           Synapse.Workspace.ReadResult.t()
           | Synapse.Workspace.MutationResult.t()
           | Synapse.Workspace.ProcessResult.t()}
          | {:error, Synapse.Workspace.Error.t()}

  @doc """
  Returns this implementation's immutable model-visible schema and trusted
  capability/effect policy.
  """
  @callback specification() :: Synapse.Tool.Spec.t()

  @doc """
  Validates model arguments and prepares one typed request without host authority.

  Expected argument failures return `{:error, :invalid_arguments}` for Executor to
  pair. A successful return must use the request type assigned to this Tool by the
  static Registry. Executor rejects a mismatched type before Workspace dispatch.
  Preparation is pure: it receives no Handle, performs no host operation, and must
  not retry or retain call state.
  """
  @callback prepare(Synapse.Tool.Call.t(), Synapse.Tool.Limits.t()) ::
              {:ok, workspace_request()} | {:error, :invalid_arguments}

  @doc """
  Presents one retained terminal Workspace outcome as a paired bounded Result.

  The Result must retain the Call's exact pairing ID and preserve whether the
  Workspace outcome completed, was known not applied/not applicable, or remains
  unknown. Presentation receives no Handle and must not redispatch or retry. The
  Executor validates pairing and result shape; malformed returns and
  exception/throw/exit failures use bounded outcome-preserving fallbacks.
  """
  @callback present(
              Synapse.Tool.Call.t(),
              workspace_outcome(),
              Synapse.Tool.Limits.t()
            ) :: Synapse.Tool.Result.t()
end
