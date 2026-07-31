# Internal dispatch contract implemented by the real and Fake Workspace backends.
defmodule Synapse.Workspace.Backend do
  @moduledoc false

  alias Synapse.Workspace.{
    EditRequest,
    Error,
    Handle,
    MutationResult,
    OperationContext,
    ProcessResult,
    ProcessSpec,
    ReadRequest,
    ReadResult,
    WriteRequest
  }

  @type event_sink :: Synapse.Workspace.event_sink()
  @type close_result :: :ok | {:error, Error.t()}

  @callback workspace_backend?() :: true
  @callback valid_handle?(Handle.t()) :: boolean()

  @callback close(Handle.t()) :: close_result()

  @callback read(Handle.t(), ReadRequest.t(), OperationContext.t()) ::
              {:ok, ReadResult.t()} | {:error, Error.t()}

  @callback write(Handle.t(), WriteRequest.t(), OperationContext.t()) ::
              {:ok, MutationResult.t()} | {:error, Error.t()}

  @callback edit(Handle.t(), EditRequest.t(), OperationContext.t()) ::
              {:ok, MutationResult.t()} | {:error, Error.t()}

  @callback run(Handle.t(), ProcessSpec.t(), event_sink(), OperationContext.t()) ::
              {:ok, ProcessResult.t()} | {:error, Error.t()}
end
