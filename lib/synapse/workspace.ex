defmodule Synapse.Workspace do
  @moduledoc """
  The exclusive Synapse boundary for project files and local project processes.

  Tool or another trusted caller supplies validated request structs and an
  operation context. Workspace revalidates limits and reduced access before
  dispatching through an opaque real or Fake handle. Results are structured;
  callers never parse terminal prose to determine success.

  The real backend provides bounded revisioned UTF-8 reads and revision-checked
  atomic whole-file creation, replacement, and exact-one text edits inside one
  temporary MutationServer. It also runs bounded commands with separated argv,
  validated cwd, a minimal environment, synchronous events, and explicit mutation
  permits.
  The API intentionally has no bang variants: expected invalid input, access,
  conflict, limit, cancellation, I/O, and ambiguity outcomes are data.

  A not-applied error guarantees that the requested mutation did not commit. An
  ambiguous error has `outcome: :unknown`; the caller must not retry blindly and
  should reconcile by reading or inspecting the workspace first.
  """

  alias Synapse.Workspace.{
    Access,
    EditRequest,
    Error,
    Handle,
    MutationResult,
    OpenRequest,
    OperationContext,
    ProcessEvent,
    ProcessResult,
    ProcessSpec,
    ReadRequest,
    ReadResult,
    WriteRequest
  }

  @typedoc "A synchronous consumer of one bounded process event."
  @type event_sink :: (ProcessEvent.t() -> :ok)

  @doc """
  Validates trusted configuration and opens one privately owned canonical root.

  The real backend monitors the configured owner and rejects unsupported hosts,
  invalid roots, and unreadable roots with sanitized errors.
  """
  @spec open(OpenRequest.t()) :: {:ok, Handle.t()} | {:error, Error.t()}
  def open(%OpenRequest{} = request) do
    case OpenRequest.new(Map.from_struct(request)) do
      {:ok, request} ->
        Synapse.Workspace.Real.open(request)

      {:error, _reason} ->
        invalid_request(:open)
    end
  end

  def open(_request), do: invalid_request(:open)

  @doc "Closes the backend represented by an opaque handle; real close is idempotent."
  @spec close(Handle.t()) :: :ok | {:error, Error.t()}
  def close(%Handle{} = handle), do: dispatch_close(handle)
  def close(_handle), do: invalid_handle(:close)

  @doc "Validates authority and a bounded read request, then dispatches to the handle backend."
  @spec read(Handle.t(), ReadRequest.t(), OperationContext.t()) ::
          {:ok, ReadResult.t()} | {:error, Error.t()}
  def read(%Handle{} = handle, %ReadRequest{} = request, %OperationContext{} = context) do
    dispatch_operation(handle, request, context, :read, :read, ReadRequest)
  end

  def read(_handle, _request, _context), do: invalid_request(:read)

  @doc "Validates write authority and a revision-checked write, then dispatches to the backend."
  @spec write(Handle.t(), WriteRequest.t(), OperationContext.t()) ::
          {:ok, MutationResult.t()} | {:error, Error.t()}
  def write(%Handle{} = handle, %WriteRequest{} = request, %OperationContext{} = context) do
    dispatch_operation(handle, request, context, :write, :write, WriteRequest)
  end

  def write(_handle, _request, _context), do: invalid_request(:write)

  @doc """
  Applies one revision-checked exact text edit through an atomic staged replacement.

  `old_text` must occur exactly once, including overlapping occurrences. Stale,
  zero-match, multiple-match, UTF-8, and generated-size failures are structured
  and leave the destination unchanged. An equal old/new replacement is a no-op
  only after proving exactly one match. Cancellation may win before admission;
  an accepted bounded edit runs to a terminal filesystem outcome.
  """
  @spec edit(Handle.t(), EditRequest.t(), OperationContext.t()) ::
          {:ok, MutationResult.t()} | {:error, Error.t()}
  def edit(%Handle{} = handle, %EditRequest{} = request, %OperationContext{} = context) do
    dispatch_operation(handle, request, context, :write, :edit, EditRequest)
  end

  def edit(_handle, _request, _context), do: invalid_request(:edit)

  @doc """
  Runs one bounded command with separated argv in a validated workspace cwd.

  The target receives a fixed secret-minimizing environment and closed stdin.
  Started and arbitrary-binary Output events are synchronous and must be accepted
  with `:ok` before MuonTrap acknowledges more output. Non-zero and signal exits
  are successful observations. Unknown-footprint commands hold the exclusive
  workspace permit; forced stops after start are ambiguous. Matching cancellation,
  accepted-output inactivity, the spec timeout, and the absolute context deadline
  all retain ownership through confirmed direct-child cleanup.
  """
  @spec run(Handle.t(), ProcessSpec.t(), event_sink(), OperationContext.t()) ::
          {:ok, ProcessResult.t()} | {:error, Error.t()}
  def run(
        %Handle{} = handle,
        %ProcessSpec{} = spec,
        event_sink,
        %OperationContext{} = context
      )
      when is_function(event_sink, 1) do
    dispatch_operation(handle, spec, context, :exec, :run, ProcessSpec, [event_sink])
  end

  def run(_handle, _spec, _event_sink, _context), do: invalid_request(:run)

  defp dispatch_close(handle) do
    with :ok <- validate_handle(handle, false),
         true <- function_exported?(handle.backend, :close, 1),
         {:backend_result, result} <- invoke_backend(handle.backend, :close, [handle]) do
      validate_backend_result(:close, result, handle.limits, nil, nil)
    else
      :backend_failed -> backend_failure(:close)
      _invalid -> invalid_handle(:close)
    end
  end

  defp dispatch_operation(
         handle,
         request,
         context,
         access_operation,
         backend_operation,
         request_module,
         extra_arguments \\ []
       ) do
    with :ok <- validate_handle(handle),
         {:ok, context} <- validate_context(handle, context),
         :ok <- authorize(handle, context, access_operation, backend_operation),
         {:ok, request} <- request_module.new(Map.from_struct(request), handle.limits),
         true <-
           function_exported?(
             handle.backend,
             backend_operation,
             3 + length(extra_arguments)
           ),
         extra_arguments <-
           prepare_extra_arguments(
             backend_operation,
             extra_arguments,
             context,
             handle.limits,
             request
           ),
         arguments <- [handle, request] ++ extra_arguments ++ [context],
         {:backend_result, result} <-
           invoke_backend(handle.backend, backend_operation, arguments) do
      validate_backend_result(backend_operation, result, handle.limits, request, context)
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, :invalid_context} ->
        invalid_request(backend_operation)

      {:error, _validation} ->
        invalid_request(backend_operation, valid_context(context))

      :backend_failed ->
        cleanup_process_event_state(backend_operation, context)
        backend_failure(backend_operation, request, context)

      false ->
        invalid_handle(backend_operation, valid_context(context))

      :error ->
        invalid_handle(backend_operation)
    end
  end

  defp validate_handle(handle, authenticate? \\ true)

  defp validate_handle(
         %Handle{
           backend: backend,
           state: state,
           token: token,
           limits: limits,
           access: access
         } = handle,
         authenticate?
       ) do
    if is_atom(backend) and (is_pid(state) or is_reference(state)) and is_reference(token) and
         Synapse.Workspace.Limits.valid?(limits) and Access.valid?(access) and
         workspace_backend?(backend) and (not authenticate? or backend_handle_valid?(handle)),
       do: :ok,
       else: :error
  end

  defp backend_handle_valid?(%Handle{backend: backend} = handle) do
    function_exported?(backend, :valid_handle?, 1) and backend.valid_handle?(handle) == true
  rescue
    _exception -> false
  catch
    _kind, _reason -> false
  end

  defp workspace_backend?(backend) do
    Code.ensure_loaded?(backend) and function_exported?(backend, :workspace_backend?, 0) and
      backend.workspace_backend?() == true
  rescue
    _exception -> false
  catch
    _kind, _reason -> false
  end

  defp validate_context(handle, context) do
    with {:ok, context} <- OperationContext.new(Map.from_struct(context), handle.limits),
         true <- Access.within?(context.access, handle.access) do
      {:ok, context}
    else
      _invalid -> {:error, :invalid_context}
    end
  end

  defp authorize(handle, context, access_operation, workspace_operation) do
    if Access.allows?(handle.access, access_operation) and
         Access.allows?(context.access, access_operation) do
      :ok
    else
      error(
        :denied,
        :access_denied,
        workspace_operation,
        "Workspace operation is not permitted",
        :not_applied,
        context
      )
    end
  end

  defp invoke_backend(backend, operation, arguments) do
    {:backend_result, apply(backend, operation, arguments)}
  rescue
    _exception -> :backend_failed
  catch
    _kind, _reason -> :backend_failed
  end

  defp prepare_extra_arguments(:run, [event_sink], context, limits, request) do
    event_state = :ets.new(:workspace_process_event_state, [:set, :public])

    :ets.insert(event_state, [
      {:sequence, 0},
      {:output, []},
      {:output_bytes, 0},
      {:max_output_bytes, request.max_output_bytes},
      {:event_count, 0},
      {:max_events, limits.max_process_events}
    ])

    Process.put(process_event_state_key(context), event_state)
    [fn event -> emit_valid_event(event, event_sink, context, limits, event_state) end]
  end

  defp prepare_extra_arguments(_operation, arguments, _context, _limits, _request), do: arguments

  defp emit_valid_event(
         %Synapse.Workspace.ProcessEvent.Started{} = event,
         sink,
         context,
         limits,
         event_state
       ) do
    with {:ok, event} <-
           Synapse.Workspace.ProcessEvent.Started.new(Map.from_struct(event), limits),
         true <- event.operation_id == context.operation_id,
         [{:event_count, event_count}] <- :ets.lookup(event_state, :event_count),
         [{:max_events, max_events}] <- :ets.lookup(event_state, :max_events),
         true <- event_count < max_events,
         true <- :ets.insert_new(event_state, {:started, true}),
         :ok <- sink.(event),
         :ok <- process_activity(context) do
      :ets.insert(event_state, {:event_count, event_count + 1})
      :ok
    else
      {:error, :activity_sink_failed} = error -> error
      _invalid -> throw(:invalid_workspace_process_event)
    end
  end

  defp emit_valid_event(
         %Synapse.Workspace.ProcessEvent.Output{} = event,
         sink,
         context,
         limits,
         event_state
       ) do
    with {:ok, event} <-
           Synapse.Workspace.ProcessEvent.Output.new(Map.from_struct(event), limits),
         true <- event.operation_id == context.operation_id,
         [{:started, true}] <- :ets.lookup(event_state, :started),
         [{:sequence, previous_sequence}] <- :ets.lookup(event_state, :sequence),
         true <- event.sequence == previous_sequence + 1,
         [{:output_bytes, output_bytes}] <- :ets.lookup(event_state, :output_bytes),
         [{:max_output_bytes, max_output_bytes}] <- :ets.lookup(event_state, :max_output_bytes),
         [{:event_count, event_count}] <- :ets.lookup(event_state, :event_count),
         [{:max_events, max_events}] <- :ets.lookup(event_state, :max_events),
         true <- event_count < max_events,
         true <- output_bytes + byte_size(event.data) <= max_output_bytes,
         :ok <- sink.(event),
         :ok <- process_activity(context) do
      [{:output, output}] = :ets.lookup(event_state, :output)

      :ets.insert(event_state, [
        {:sequence, event.sequence},
        {:output, [event.data | output]},
        {:output_bytes, output_bytes + byte_size(event.data)},
        {:event_count, event_count + 1}
      ])

      :ok
    else
      {:error, :activity_sink_failed} = error -> error
      _invalid -> throw(:invalid_workspace_process_event)
    end
  end

  defp emit_valid_event(_event, _sink, _context, _limits, _event_state),
    do: throw(:invalid_workspace_process_event)

  defp process_activity(%{activity_sink: nil}), do: :ok

  defp process_activity(%{activity_sink: sink} = context) do
    case sink.(context) do
      :ok -> :ok
      _invalid -> {:error, :activity_sink_failed}
    end
  rescue
    _exception -> {:error, :activity_sink_failed}
  catch
    _kind, _reason -> {:error, :activity_sink_failed}
  end

  defp validate_backend_result(:close, :ok, _limits, _request, _context), do: :ok

  defp validate_backend_result(operation, {:error, %Error{} = error}, limits, request, context) do
    result =
      if Error.valid?(error, limits) and error_matches?(error, operation, request, context),
        do: {:error, error},
        else: backend_failure(operation, request, context)

    cleanup_process_event_state(operation, context)
    result
  end

  defp validate_backend_result(:read, {:ok, %ReadResult{} = result}, limits, request, context) do
    case ReadResult.new(Map.from_struct(result), limits) do
      {:ok, result} ->
        if read_result_matches?(result, request),
          do: {:ok, result},
          else: backend_failure(:read, request, context)

      {:error, _reason} ->
        backend_failure(:read, nil, context)
    end
  end

  defp validate_backend_result(
         operation,
         {:ok, %MutationResult{} = result},
         limits,
         request,
         context
       )
       when operation in [:write, :edit] do
    case MutationResult.new(Map.from_struct(result), limits) do
      {:ok, result} ->
        if mutation_result_matches?(result, request, context),
          do: {:ok, result},
          else: backend_failure(operation, request, context)

      {:error, _reason} ->
        backend_failure(operation, request, context)
    end
  end

  defp validate_backend_result(:run, {:ok, %ProcessResult{} = result}, limits, request, context) do
    validated =
      case ProcessResult.new(Map.from_struct(result), limits) do
        {:ok, result} ->
          if process_result_matches?(result, request, context, limits) and
               process_events_match_result?(result, context),
             do: {:ok, result},
             else: backend_failure(:run, request, context)

        {:error, _reason} ->
          backend_failure(:run, request, context)
      end

    cleanup_process_event_state(:run, context)
    validated
  end

  defp validate_backend_result(operation, _result, _limits, request, context) do
    cleanup_process_event_state(operation, context)
    backend_failure(operation, request, context)
  end

  defp read_result_matches?(result, request) do
    result.path == request.path and length(result.lines) <= request.line_count and
      read_result_bytes(result) <= request.max_bytes and
      (result.lines == [] or hd(result.lines).number == request.start_line)
  end

  defp read_result_bytes(result) do
    Enum.reduce(result.lines, 0, fn line, total ->
      ending_bytes =
        if line.truncated,
          do: 0,
          else: if(line.ending == :crlf, do: 2, else: if(line.ending == :lf, do: 1, else: 0))

      total + byte_size(line.text) + ending_bytes
    end)
  end

  defp mutation_result_matches?(result, %WriteRequest{} = request, context) do
    result.path == request.path and result.operation_id == context.operation_id and
      result.previous_revision == request.expected_revision and
      (not result.changed or result.bytes_written == byte_size(request.content))
  end

  defp mutation_result_matches?(result, %EditRequest{} = request, context) do
    result.path == request.path and result.operation_id == context.operation_id and
      result.previous_revision == request.expected_revision and
      result.changed == (request.old_text != request.new_text)
  end

  defp process_result_matches?(result, spec, context, limits) do
    result.operation_id == context.operation_id and
      byte_size(result.output) <= spec.max_output_bytes and
      result.output_bytes <= spec.max_output_bytes + limits.max_process_event_bytes and
      result.elapsed_ms <= spec.timeout_ms + 2 * limits.kill_grace_ms and
      (spec.mutation != :unknown or result.termination == :exited)
  end

  defp process_events_match_result?(result, context) do
    case Process.get(process_event_state_key(context)) do
      event_state when is_reference(event_state) ->
        with [{:started, true}] <- :ets.lookup(event_state, :started),
             [{:output, output}] <- :ets.lookup(event_state, :output) do
          output |> Enum.reverse() |> IO.iodata_to_binary() == result.output
        else
          _missing -> false
        end

      _missing ->
        false
    end
  end

  defp cleanup_process_event_state(:run, %OperationContext{} = context) do
    case Process.delete(process_event_state_key(context)) do
      event_state when is_reference(event_state) ->
        try do
          :ets.delete(event_state)
        rescue
          _exception -> :ok
        end

      _missing ->
        :ok
    end
  end

  defp cleanup_process_event_state(_operation, _context), do: :ok

  defp process_event_state_key(context),
    do: {__MODULE__, :process_event_state, context.operation_id}

  defp error_matches?(error, operation, request, context) do
    error.operation == operation and error.operation_id == operation_id(context) and
      path_matches?(error, request)
  end

  defp path_matches?(error, request) do
    requested_path = request_path(request)

    if path_specific_reason?(error.reason),
      do: error.path == requested_path,
      else: is_nil(error.path) or error.path == requested_path
  end

  defp path_specific_reason?(reason),
    do:
      reason in [
        :not_found,
        :absolute_path,
        :path_traversal,
        :invalid_utf8,
        :path_too_long,
        :symlink,
        :broken_link,
        :mount_crossing,
        :multiple_hard_links,
        :not_regular_file,
        :file_changed,
        :file_too_large,
        :stale_revision,
        :expected_missing,
        :no_match,
        :multiple_matches,
        :cancelled,
        :deadline_elapsed,
        :activity_sink_failed,
        :not_implemented,
        :invalid_root,
        :io
      ]

  defp request_path(%{path: path}), do: path
  defp request_path(%ProcessSpec{cwd: cwd}), do: cwd
  defp request_path(_request), do: nil

  defp backend_failure(operation, request \\ nil, context \\ nil)

  defp backend_failure(operation, %ProcessSpec{mutation: :unknown}, context) do
    error(
      :ambiguous,
      :backend_unavailable,
      operation,
      "Workspace backend failed after operation admission",
      :unknown,
      valid_context(context)
    )
  end

  defp backend_failure(operation, _request, context) when operation in [:write, :edit] do
    error(
      :ambiguous,
      :backend_unavailable,
      operation,
      "Workspace backend failed after operation admission",
      :unknown,
      valid_context(context)
    )
  end

  defp backend_failure(operation, _request, context) do
    error(
      :unavailable,
      :backend_unavailable,
      operation,
      "Workspace backend is unavailable",
      :not_applicable,
      valid_context(context)
    )
  end

  defp invalid_handle(operation, context \\ nil) do
    error(
      :unavailable,
      :invalid_handle,
      operation,
      "Workspace handle is invalid or unavailable",
      :not_applicable,
      context
    )
  end

  defp invalid_request(operation, context \\ nil) do
    error(
      :invalid,
      :invalid_request,
      operation,
      "Workspace request is invalid",
      :not_applied,
      context
    )
  end

  defp error(kind, reason, operation, message, outcome, context) do
    attrs = [
      kind: kind,
      reason: reason,
      operation: operation,
      message: message,
      outcome: outcome,
      operation_id: operation_id(context)
    ]

    {:ok, error} = Error.new(attrs)
    {:error, error}
  end

  defp valid_context(%OperationContext{} = context) do
    if Synapse.Workspace.Validation.bounded_string?(context.operation_id, 256, false),
      do: context,
      else: nil
  end

  defp valid_context(_context), do: nil

  defp operation_id(%OperationContext{} = context) do
    case valid_context(context) do
      %OperationContext{operation_id: operation_id} -> operation_id
      nil -> nil
    end
  end

  defp operation_id(_context), do: nil
end
