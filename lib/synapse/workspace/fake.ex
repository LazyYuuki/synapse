defmodule Synapse.Workspace.Fake.Entry do
  @moduledoc """
  One exact expected Workspace operation in a deterministic Fake script.

  Build entries with `Synapse.Workspace.Fake.expect_read/3`, `expect_write/3`,
  `expect_edit/3`, or `expect_run/4`. The request and operation context are compared exactly after the
  Workspace facade normalizes them. Run entries additionally emit their process
  events synchronously in source order.
  """

  alias Synapse.Workspace.{OperationContext, ProcessEvent}

  @enforce_keys [:operation, :request, :context, :events, :result]
  defstruct @enforce_keys

  @typedoc "A supported scripted Workspace operation."
  @type operation :: :read | :write | :edit | :run

  @typedoc "An exact request/context expectation, events, and terminal result."
  @type t :: %__MODULE__{
          operation: operation(),
          request: struct(),
          context: OperationContext.t(),
          events: [ProcessEvent.t()],
          result: term()
        }
end

defmodule Synapse.Workspace.Fake do
  @moduledoc """
  A deterministic scripted Workspace backend with no host side effects.

  Fake belongs inside Workspace because Tool tests should exercise the same
  request, context, result, error, access, limit, event, and handle boundary as
  the real backend. Tests should not emulate files, revisions, process Ports, or
  environment setup themselves.

  Scripts contain exact entries built by `expect_read/3`, `expect_write/3`,
  `expect_edit/3`, and `expect_run/4`. Entries are consumed once in source order. Request or context mismatch
  consumes that entry and returns `:unexpected_operation`; a call after the last
  entry returns `:script_exhausted`. Run events are delivered synchronously before
  the scripted terminal result.

  Fake proves how a caller uses Workspace contracts. It cannot prove canonical
  path containment, filesystem races or durability, environment stripping,
  process termination, or descendant containment; real temporary-workspace tests
  remain required for those properties.

  ## Example

      read_entry = Synapse.Workspace.Fake.expect_read(read_request, read_context, {:ok, read_result})
      edit_entry = Synapse.Workspace.Fake.expect_edit(edit_request, edit_context, {:ok, edit_result})

      run_entry =
        Synapse.Workspace.Fake.expect_run(
          process_spec,
          run_context,
          [started_event, output_event],
          {:ok, process_result}
        )

      {:ok, handle} = Synapse.Workspace.Fake.open([read_entry, edit_entry, run_entry])
      {:ok, ^read_result} = Synapse.Workspace.read(handle, read_request, read_context)
      {:ok, ^edit_result} = Synapse.Workspace.edit(handle, edit_request, edit_context)
      {:ok, ^process_result} =
        Synapse.Workspace.run(handle, process_spec, fn _event -> :ok end, run_context)
      :ok = Synapse.Workspace.Fake.assert_finished(handle)
      :ok = Synapse.Workspace.close(handle)

  An exhausted script is a structured Workspace failure:

      iex> {:ok, access} = Synapse.Workspace.Access.new(read: true, write: true, exec: true)
      iex> {:ok, context} = Synapse.Workspace.OperationContext.new(
      ...>   operation_id: "fake-exhausted-doc", access: access
      ...> )
      iex> {:ok, request} = Synapse.Workspace.ReadRequest.new(path: "example.txt")
      iex> {:ok, handle} = Synapse.Workspace.Fake.open([])
      iex> {:error, error} = Synapse.Workspace.read(handle, request, context)
      iex> error.reason
      :script_exhausted
      iex> Synapse.Workspace.close(handle)
      :ok
  """

  @behaviour Synapse.Workspace.Backend

  alias Synapse.Workspace.{
    Access,
    EditRequest,
    Error,
    Fake.Entry,
    Handle,
    Limits,
    MutationResult,
    OperationContext,
    ProcessEvent,
    ProcessResult,
    ProcessSpec,
    ReadRequest,
    ReadResult,
    Validation,
    WriteRequest
  }

  @typedoc "A source-ordered sequence of exact Workspace expectations."
  @type script :: [Entry.t()]

  @typedoc "A Fake-construction failure before an opaque handle exists."
  @type open_error :: :invalid_options | :invalid_script | :owner_unavailable

  @doc "Builds an exact scripted read entry."
  @spec expect_read(
          ReadRequest.t(),
          OperationContext.t(),
          {:ok, ReadResult.t()} | {:error, Error.t()}
        ) ::
          Entry.t()
  def expect_read(%ReadRequest{} = request, %OperationContext{} = context, result),
    do: entry(:read, request, context, [], result)

  @doc "Builds an exact scripted whole-file write entry."
  @spec expect_write(
          WriteRequest.t(),
          OperationContext.t(),
          {:ok, MutationResult.t()} | {:error, Error.t()}
        ) :: Entry.t()
  def expect_write(%WriteRequest{} = request, %OperationContext{} = context, result),
    do: entry(:write, request, context, [], result)

  @doc "Builds an exact scripted exact-edit entry."
  @spec expect_edit(
          EditRequest.t(),
          OperationContext.t(),
          {:ok, MutationResult.t()} | {:error, Error.t()}
        ) :: Entry.t()
  def expect_edit(%EditRequest{} = request, %OperationContext{} = context, result),
    do: entry(:edit, request, context, [], result)

  @doc "Builds an exact scripted process entry with synchronous ordered events."
  @spec expect_run(
          ProcessSpec.t(),
          OperationContext.t(),
          [ProcessEvent.t()],
          {:ok, ProcessResult.t()} | {:error, Error.t()}
        ) :: Entry.t()
  def expect_run(%ProcessSpec{} = spec, %OperationContext{} = context, events, result)
      when is_list(events),
      do: entry(:run, spec, context, events, result)

  @doc "Opens an opaque Fake handle after validating the complete bounded script."
  @spec open(script(), keyword()) :: {:ok, Handle.t()} | {:error, open_error()}
  def open(script, options \\ []) do
    with {:ok, options} <- validate_options(options),
         limits <- Keyword.get(options, :limits, Limits.default()),
         access <- Keyword.get(options, :access, full_access()),
         owner <- Keyword.get(options, :owner, self()),
         true <- Limits.valid?(limits),
         true <- Access.valid?(access),
         true <- is_pid(owner) and Process.alive?(owner),
         :ok <- validate_script(script, limits, access),
         token <- make_ref(),
         {:ok, server} <-
           Synapse.Workspace.Fake.Server.start(owner, token, script, limits, access) do
      {:ok,
       %Handle{
         backend: __MODULE__,
         state: server,
         token: token,
         limits: limits,
         access: access
       }}
    else
      {:error, :invalid_options} -> {:error, :invalid_options}
      {:error, :invalid_script} -> {:error, :invalid_script}
      false -> {:error, :invalid_options}
      {:error, _reason} -> {:error, :owner_unavailable}
    end
  end

  @doc "Returns the number of entries not yet consumed by an open Fake handle."
  @spec remaining_operations(Handle.t()) ::
          {:ok, non_neg_integer()} | {:error, :invalid_handle}
  def remaining_operations(%Handle{backend: __MODULE__} = handle) do
    call_server(handle, :remaining)
  end

  def remaining_operations(_handle), do: {:error, :invalid_handle}

  @doc "Returns `:ok` only when every scripted operation was consumed."
  @spec assert_finished(Handle.t()) ::
          :ok | {:error, {:remaining_operations, pos_integer()}} | {:error, :invalid_handle}
  def assert_finished(handle) do
    case remaining_operations(handle) do
      {:ok, 0} -> :ok
      {:ok, remaining} -> {:error, {:remaining_operations, remaining}}
      {:error, :invalid_handle} = error -> error
    end
  end

  @impl true
  @doc false
  def workspace_backend?, do: true

  @impl true
  @doc false
  def valid_handle?(%Handle{backend: __MODULE__} = handle) do
    call_server(handle, {:valid, handle.limits, handle.access}) == true
  end

  def valid_handle?(_handle), do: false

  @impl true
  @doc false
  def close(%Handle{backend: __MODULE__} = handle) do
    case call_server(handle, :close) do
      :ok -> :ok
      :closing -> await_server_close(handle.state)
      {:error, :invalid_handle} -> fake_error(:close, nil, nil, :invalid_handle)
    end
  end

  @impl true
  @doc false
  def read(handle, request, context), do: execute(handle, :read, request, context)

  @impl true
  @doc false
  def write(handle, request, context), do: execute(handle, :write, request, context)

  @impl true
  @doc false
  def edit(handle, request, context), do: execute(handle, :edit, request, context)

  @impl true
  @doc false
  def run(handle, spec, event_sink, context) do
    with :ok <- pre_operation_lifetime(context, :run, spec, handle.limits) do
      with_entry(handle, :run, spec, context, fn entry, lease ->
        with {:ok, output, started?} <-
               emit_events(
                 entry.events,
                 event_sink,
                 context,
                 spec,
                 handle,
                 lease,
                 [],
                 false
               ) do
          case operation_lifetime(handle, lease, context) do
            :ok ->
              entry.result

            {:error, reason} ->
              interrupted_run(spec, context, reason, output, started?, handle.limits)
          end
        else
          {:error, %Error{} = error} ->
            {:error, error}

          {:interrupted, reason, output, started?} ->
            interrupted_run(spec, context, reason, output, started?, handle.limits)
        end
      end)
    else
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp entry(operation, request, context, events, result) do
    %Entry{
      operation: operation,
      request: request,
      context: context,
      events: events,
      result: result
    }
  end

  defp execute(handle, operation, request, context) do
    with :ok <- pre_operation_lifetime(context, operation, request, handle.limits) do
      with_entry(handle, operation, request, context, fn entry, lease ->
        if active_operation?(handle, lease) do
          result =
            notify_result_activity(entry.result, operation, request, context, handle.limits)

          if active_operation?(handle, lease),
            do: result,
            else: invalidated_file_result(result, operation, request, context, handle.limits)
        else
          fake_error(operation, request, context, :invalid_handle, handle.limits)
        end
      end)
    else
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp with_entry(handle, operation, request, context, callback) do
    case take_entry(handle, operation, request, context) do
      {:ok, entry, lease} ->
        try do
          callback.(entry, lease)
        after
          finish_entry(handle, lease)
        end

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp take_entry(handle, operation, request, context) do
    case call_server(handle, :take) do
      {:ok, %Entry{} = entry, lease} ->
        if entry.operation == operation and entry.request == request and entry.context == context,
          do: {:ok, entry, lease},
          else: unexpected_entry(handle, lease, operation, request, context)

      {:error, :script_exhausted} ->
        fake_error(operation, request, context, :script_exhausted, handle.limits)

      {:error, :invalid_handle} ->
        fake_error(operation, request, context, :invalid_handle, handle.limits)

      {:error, :workspace_busy} ->
        fake_error(operation, request, context, :workspace_busy, handle.limits)
    end
  end

  defp unexpected_entry(handle, lease, operation, request, context) do
    finish_entry(handle, lease)
    fake_error(operation, request, context, :unexpected_operation, handle.limits)
  end

  defp emit_events([], _event_sink, _context, _spec, _handle, _lease, output, started?),
    do: {:ok, output |> Enum.reverse() |> IO.iodata_to_binary(), started?}

  defp emit_events(
         [event | remaining],
         event_sink,
         context,
         spec,
         handle,
         lease,
         output,
         started?
       ) do
    case operation_lifetime(handle, lease, context) do
      :ok ->
        case emit_event(event_sink, event) do
          :ok ->
            {output, started?} =
              case event do
                %ProcessEvent.Output{data: data} -> {[data | output], started?}
                %ProcessEvent.Started{} -> {output, true}
              end

            emit_events(
              remaining,
              event_sink,
              context,
              spec,
              handle,
              lease,
              output,
              started?
            )

          {:error, reason} ->
            fake_process_error(spec, context, reason, handle.limits)
        end

      {:error, reason} ->
        {:interrupted, reason, output |> Enum.reverse() |> IO.iodata_to_binary(), started?}
    end
  end

  defp emit_event(event_sink, event) do
    case event_sink.(event) do
      :ok -> :ok
      {:error, :activity_sink_failed} -> {:error, :activity_sink_failed}
      _invalid -> {:error, :event_sink_failed}
    end
  rescue
    _exception -> {:error, :event_sink_failed}
  catch
    _kind, _reason -> {:error, :event_sink_failed}
  end

  defp interrupted_run(spec, context, reason, _output, false, limits),
    do: fake_error(:run, spec, context, reason, limits)

  defp interrupted_run(spec, context, reason, _output, true, limits)
       when reason not in [:cancelled, :deadline_elapsed],
       do: fake_process_error(spec, context, reason, limits)

  defp interrupted_run(%{mutation: :read_only}, context, reason, output, true, limits) do
    termination = if reason == :cancelled, do: :cancelled, else: :timed_out

    ProcessResult.new(
      %{
        operation_id: context.operation_id,
        termination: termination,
        exit_code: nil,
        output: output,
        output_bytes: byte_size(output),
        truncated: false,
        elapsed_ms: 0
      },
      limits
    )
  end

  defp interrupted_run(%{mutation: :unknown} = spec, context, reason, _output, true, limits),
    do: fake_process_error(spec, context, reason, limits)

  defp fake_process_error(spec, context, reason, limits) do
    outcome = if spec.mutation == :unknown, do: :unknown, else: :not_applicable
    kind = if outcome == :unknown, do: :ambiguous, else: error_kind(reason)

    error_result(kind, reason, :run, outcome, context, spec, limits)
  end

  defp pre_operation_lifetime(context, operation, request, limits) do
    case lifetime_interruption(context) do
      :ok -> :ok
      {:error, reason} -> fake_error(operation, request, context, reason, limits)
    end
  end

  defp lifetime_interruption(context) do
    cond do
      deadline_elapsed?(context.deadline) -> {:error, :deadline_elapsed}
      cancelled?(context.cancel_ref) -> {:error, :cancelled}
      true -> :ok
    end
  end

  defp operation_lifetime(handle, lease, context) do
    if active_operation?(handle, lease),
      do: lifetime_interruption(context),
      else: {:error, :invalid_handle}
  end

  defp active_operation?(handle, lease),
    do: call_server(handle, {:active, lease}) == true

  defp finish_entry(handle, lease) do
    _result = call_server(handle, {:finish, lease})
    :ok
  end

  defp cancelled?(nil), do: false

  defp cancelled?(cancel_ref) do
    receive do
      {:cancel, ^cancel_ref} -> true
    after
      0 -> false
    end
  end

  defp deadline_elapsed?(:infinity), do: false
  defp deadline_elapsed?(deadline), do: :erlang.monotonic_time(:millisecond) >= deadline

  defp notify_result_activity({:ok, result}, operation, request, context, limits)
       when operation in [:read, :write, :edit] do
    case notify_activity(context) do
      :ok -> {:ok, result}
      :error -> activity_failure(operation, request, context, result, limits)
    end
  end

  defp notify_result_activity(result, _operation, _request, _context, _limits), do: result

  defp invalidated_file_result(
         {:ok, %MutationResult{changed: true}},
         operation,
         request,
         context,
         limits
       ),
       do:
         error_result(
           :ambiguous,
           :backend_unavailable,
           operation,
           :unknown,
           context,
           request,
           limits
         )

  defp invalidated_file_result(
         {:error, %Error{outcome: :unknown}} = result,
         _operation,
         _request,
         _context,
         _limits
       ),
       do: result

  defp invalidated_file_result(_result, operation, request, context, limits),
    do: fake_error(operation, request, context, :invalid_handle, limits)

  defp notify_activity(%{activity_sink: nil}), do: :ok

  defp notify_activity(%{activity_sink: sink} = context) do
    if sink.(context) == :ok, do: :ok, else: :error
  rescue
    _exception -> :error
  catch
    _kind, _reason -> :error
  end

  defp activity_failure(operation, request, context, %MutationResult{changed: true}, limits),
    do:
      error_result(
        :ambiguous,
        :mutation_activity_failed,
        operation,
        :unknown,
        context,
        request,
        limits
      )

  defp activity_failure(:read, request, context, _result, limits),
    do:
      error_result(
        :unavailable,
        :activity_sink_failed,
        :read,
        :not_applicable,
        context,
        request,
        limits
      )

  defp activity_failure(operation, request, context, _result, limits),
    do:
      error_result(
        :unavailable,
        :activity_sink_failed,
        operation,
        :not_applied,
        context,
        request,
        limits
      )

  defp fake_error(operation, request, context, reason, limits \\ Limits.default()) do
    outcome = mutation_outcome(operation, request)
    error_result(error_kind(reason), reason, operation, outcome, context, request, limits)
  end

  defp mutation_outcome(operation, %ProcessSpec{mutation: :unknown}) when operation == :run,
    do: :not_applied

  defp mutation_outcome(operation, _request) when operation in [:write, :edit], do: :not_applied
  defp mutation_outcome(_operation, _request), do: :not_applicable

  defp error_kind(:cancelled), do: :cancelled
  defp error_kind(:deadline_elapsed), do: :cancelled
  defp error_kind(:invalid_handle), do: :unavailable
  defp error_kind(:activity_sink_failed), do: :unavailable
  defp error_kind(:event_sink_failed), do: :unavailable
  defp error_kind(:workspace_busy), do: :conflict
  defp error_kind(:unexpected_operation), do: :invalid
  defp error_kind(:script_exhausted), do: :unavailable

  defp error_result(kind, reason, operation, outcome, context, request, limits) do
    attrs = [
      kind: kind,
      reason: reason,
      operation: operation,
      message: error_message(reason),
      outcome: outcome,
      operation_id: if(context, do: context.operation_id),
      path: error_path(reason, request)
    ]

    {:ok, error} = Error.new(attrs, limits)
    {:error, error}
  end

  defp error_message(:cancelled), do: "Fake Workspace operation was cancelled"
  defp error_message(:deadline_elapsed), do: "Fake Workspace operation deadline elapsed"
  defp error_message(:invalid_handle), do: "Fake Workspace handle is invalid"
  defp error_message(:activity_sink_failed), do: "Fake Workspace activity sink failed"
  defp error_message(:event_sink_failed), do: "Fake Workspace event sink rejected an event"
  defp error_message(:workspace_busy), do: "Fake Workspace operation capacity is busy"
  defp error_message(:mutation_activity_failed), do: "Fake Workspace mutation activity failed"
  defp error_message(:backend_unavailable), do: "Fake Workspace owner became unavailable"
  defp error_message(:unexpected_operation), do: "Fake Workspace received an unexpected operation"
  defp error_message(:script_exhausted), do: "Fake Workspace script is exhausted"

  defp error_path(reason, request)
       when reason in [
              :cancelled,
              :deadline_elapsed,
              :event_sink_failed,
              :inactivity_timeout,
              :activity_sink_failed,
              :mutation_activity_failed
            ] do
    request_path(request)
  end

  defp error_path(_reason, _request), do: nil

  defp request_path(%{path: path}), do: path
  defp request_path(%ProcessSpec{cwd: cwd}), do: cwd
  defp request_path(_request), do: nil

  defp validate_options(options) when is_list(options) do
    if Validation.bounded_proper_list?(options, 3) and Keyword.keyword?(options) and
         Keyword.keys(options) -- [:limits, :access, :owner] == [],
       do: {:ok, options},
       else: {:error, :invalid_options}
  end

  defp validate_options(_options), do: {:error, :invalid_options}

  defp validate_script(script, limits, access) when is_list(script) do
    if Validation.bounded_proper_list?(script, limits.max_fake_script_entries) and
         Enum.all?(script, &valid_entry?(&1, limits, access)),
       do: :ok,
       else: {:error, :invalid_script}
  end

  defp validate_script(_script, _limits, _access), do: {:error, :invalid_script}

  defp valid_entry?(%Entry{} = entry, limits, access) do
    with {:ok, context} <- OperationContext.new(Map.from_struct(entry.context), limits),
         true <- Access.within?(context.access, access),
         true <- entry_accessible?(entry.operation, access, context.access),
         {:ok, request} <- validate_entry_request(entry.operation, entry.request, limits),
         true <- request == entry.request,
         true <- valid_entry_events?(entry.operation, entry.events, limits),
         true <- valid_entry_result?(entry.operation, entry.result, limits),
         true <- entry_consistent?(entry, limits) do
      true
    else
      _invalid -> false
    end
  end

  defp valid_entry?(_entry, _limits, _access), do: false

  defp entry_accessible?(operation, handle_access, context_access) do
    access_operation = if operation == :run, do: :exec, else: operation_access(operation)

    Access.allows?(handle_access, access_operation) and
      Access.allows?(context_access, access_operation)
  end

  defp operation_access(:read), do: :read
  defp operation_access(operation) when operation in [:write, :edit], do: :write

  defp validate_entry_request(:read, %ReadRequest{} = request, limits),
    do: ReadRequest.new(Map.from_struct(request), limits)

  defp validate_entry_request(:write, %WriteRequest{} = request, limits),
    do: WriteRequest.new(Map.from_struct(request), limits)

  defp validate_entry_request(:edit, %EditRequest{} = request, limits),
    do: EditRequest.new(Map.from_struct(request), limits)

  defp validate_entry_request(:run, %ProcessSpec{} = request, limits),
    do: ProcessSpec.new(Map.from_struct(request), limits)

  defp validate_entry_request(_operation, _request, _limits), do: {:error, :invalid}

  defp valid_entry_events?(:run, events, limits) when is_list(events),
    do:
      Validation.bounded_proper_list?(events, limits.max_process_events) and
        Enum.all?(events, &valid_event?(&1, limits))

  defp valid_entry_events?(operation, [], _limits) when operation in [:read, :write, :edit],
    do: true

  defp valid_entry_events?(_operation, _events, _limits), do: false

  defp valid_event?(%ProcessEvent.Started{} = event, limits),
    do: match?({:ok, _event}, ProcessEvent.Started.new(Map.from_struct(event), limits))

  defp valid_event?(%ProcessEvent.Output{} = event, limits),
    do: match?({:ok, _event}, ProcessEvent.Output.new(Map.from_struct(event), limits))

  defp valid_event?(_event, _limits), do: false

  defp valid_entry_result?(:read, {:ok, %ReadResult{} = result}, limits),
    do: match?({:ok, _result}, ReadResult.new(Map.from_struct(result), limits))

  defp valid_entry_result?(operation, {:ok, %MutationResult{} = result}, limits)
       when operation in [:write, :edit],
       do: match?({:ok, _result}, MutationResult.new(Map.from_struct(result), limits))

  defp valid_entry_result?(:run, {:ok, %ProcessResult{} = result}, limits),
    do: match?({:ok, _result}, ProcessResult.new(Map.from_struct(result), limits))

  defp valid_entry_result?(_operation, {:error, %Error{} = error}, limits),
    do: Error.valid?(error, limits)

  defp valid_entry_result?(_operation, _result, _limits), do: false

  defp entry_consistent?(%Entry{result: {:error, %Error{} = error}} = entry, _limits),
    do: error_matches_entry?(error, entry)

  defp entry_consistent?(
         %Entry{operation: :read, request: request, result: {:ok, result}},
         _limits
       ),
       do: read_result_matches?(result, request)

  defp entry_consistent?(
         %Entry{operation: operation, request: request, context: context, result: {:ok, result}},
         _limits
       )
       when operation in [:write, :edit],
       do: mutation_result_matches?(operation, result, request, context)

  defp entry_consistent?(
         %Entry{
           operation: :run,
           request: spec,
           context: context,
           events: events,
           result: {:ok, result}
         },
         limits
       ),
       do: run_success_matches?(spec, context, events, result, limits)

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

  defp mutation_result_matches?(:write, result, request, context) do
    result.path == request.path and result.operation_id == context.operation_id and
      result.previous_revision == request.expected_revision and
      (not result.changed or result.bytes_written == byte_size(request.content))
  end

  defp mutation_result_matches?(:edit, result, request, context) do
    result.path == request.path and result.operation_id == context.operation_id and
      result.previous_revision == request.expected_revision and
      result.changed == (request.old_text != request.new_text)
  end

  defp run_success_matches?(spec, context, events, result, limits) do
    with {:ok, output} <-
           valid_process_events(events, context.operation_id, spec.max_output_bytes),
         true <- output == result.output,
         true <- result.operation_id == context.operation_id,
         true <- byte_size(result.output) <= spec.max_output_bytes,
         true <- result.output_bytes <= spec.max_output_bytes + limits.max_process_event_bytes,
         true <- result.elapsed_ms <= spec.timeout_ms + 2 * limits.kill_grace_ms,
         true <- spec.mutation != :unknown or result.termination == :exited do
      true
    else
      _invalid -> false
    end
  end

  defp valid_process_events(
         [%ProcessEvent.Started{operation_id: operation_id} | output_events],
         operation_id,
         max_output_bytes
       ) do
    output_events
    |> Enum.reduce_while({0, 0, []}, fn
      %ProcessEvent.Output{operation_id: ^operation_id, sequence: sequence, data: data},
      {previous, bytes, output}
      when sequence == previous + 1 ->
        bytes = bytes + byte_size(data)

        if bytes <= max_output_bytes,
          do: {:cont, {sequence, bytes, [data | output]}},
          else: {:halt, :invalid}

      _invalid, _state ->
        {:halt, :invalid}
    end)
    |> case do
      {_sequence, _bytes, output} ->
        {:ok, output |> Enum.reverse() |> IO.iodata_to_binary()}

      :invalid ->
        :error
    end
  end

  defp valid_process_events(_events, _operation_id, _max_output_bytes), do: :error

  defp error_matches_entry?(error, entry) do
    error.operation == entry.operation and
      error.operation_id == entry.context.operation_id and
      scripted_error_path_matches?(error, entry.request) and
      valid_error_events?(entry)
  end

  defp valid_error_events?(%Entry{operation: :run, events: []}), do: true

  defp valid_error_events?(%Entry{
         operation: :run,
         events: events,
         context: context,
         request: spec
       }),
       do:
         match?(
           {:ok, _output},
           valid_process_events(events, context.operation_id, spec.max_output_bytes)
         )

  defp valid_error_events?(%Entry{events: []}), do: true
  defp valid_error_events?(_entry), do: false

  defp scripted_error_path_matches?(error, request) do
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

  defp full_access do
    {:ok, access} = Access.new(read: true, write: true, exec: true)
    access
  end

  defp call_server(%Handle{} = handle, request) do
    GenServer.call(handle.state, {request, handle.token})
  catch
    :exit, _reason -> {:error, :invalid_handle}
  end

  defp await_server_close(server) do
    monitor = Process.monitor(server)

    receive do
      {:DOWN, ^monitor, :process, ^server, _reason} -> :ok
    end
  end
end

defmodule Synapse.Workspace.Fake.Server do
  @moduledoc false

  use GenServer

  @enforce_keys [
    :owner,
    :owner_monitor,
    :token,
    :script,
    :active,
    :close_waiter,
    :limits,
    :access
  ]
  defstruct @enforce_keys

  def start(owner, token, script, limits, access),
    do: GenServer.start(__MODULE__, {owner, token, script, limits, access})

  @impl true
  def init({owner, token, script, limits, access}) do
    monitor = Process.monitor(owner)

    {:ok,
     %__MODULE__{
       owner: owner,
       owner_monitor: monitor,
       token: token,
       script: script,
       active: %{},
       close_waiter: nil,
       limits: limits,
       access: access
     }}
  end

  @impl true
  def handle_call({{:valid, limits, access}, token}, _from, state) do
    valid =
      token == state.token and limits == state.limits and access == state.access and
        is_nil(state.close_waiter)

    {:reply, valid, state}
  end

  def handle_call({:remaining, token}, _from, %{token: token} = state),
    do: {:reply, {:ok, length(state.script)}, state}

  def handle_call({:take, token}, _from, %{token: token, close_waiter: close_waiter} = state)
      when not is_nil(close_waiter),
      do: {:reply, {:error, :invalid_handle}, state}

  def handle_call({:take, token}, _from, %{token: token} = state)
      when map_size(state.active) >= state.limits.max_concurrent_operations,
      do: {:reply, {:error, :workspace_busy}, state}

  def handle_call(
        {:take, token},
        {holder, _tag},
        %{token: token, script: [entry | remaining]} = state
      ) do
    lease = make_ref()
    monitor = Process.monitor(holder)
    active = Map.put(state.active, lease, %{holder: holder, monitor: monitor})
    {:reply, {:ok, entry, lease}, %{state | script: remaining, active: active}}
  end

  def handle_call({:take, token}, _from, %{token: token, script: []} = state),
    do: {:reply, {:error, :script_exhausted}, state}

  def handle_call({{:active, lease}, token}, {holder, _tag}, %{token: token} = state) do
    {:reply, match?(%{holder: ^holder}, state.active[lease]), state}
  end

  def handle_call({{:finish, lease}, token}, {holder, _tag}, %{token: token} = state) do
    case state.active[lease] do
      %{holder: ^holder, monitor: monitor} ->
        Process.demonitor(monitor, [:flush])
        state = %{state | active: Map.delete(state.active, lease)}

        if map_size(state.active) == 0 and not is_nil(state.close_waiter) do
          GenServer.reply(state.close_waiter, :ok)
          {:stop, :normal, :ok, %{state | close_waiter: nil}}
        else
          {:reply, :ok, state}
        end

      _missing ->
        {:reply, {:error, :invalid_handle}, state}
    end
  end

  def handle_call({:close, token}, from, %{token: token} = state) do
    cond do
      not is_nil(state.close_waiter) ->
        {:reply, :closing, state}

      map_size(state.active) == 0 ->
        {:stop, :normal, :ok, state}

      true ->
        {:noreply, %{state | close_waiter: from}}
    end
  end

  def handle_call(_request, _from, state), do: {:reply, {:error, :invalid_handle}, state}

  @impl true
  def handle_info({:DOWN, monitor, :process, owner, _reason}, state)
      when monitor == state.owner_monitor and owner == state.owner,
      do: {:stop, :normal, state}

  def handle_info({:DOWN, monitor, :process, holder, _reason}, state) do
    active =
      Map.reject(state.active, fn {_lease, operation} ->
        operation.monitor == monitor and operation.holder == holder
      end)

    state = %{state | active: active}

    if map_size(active) == 0 and not is_nil(state.close_waiter) do
      GenServer.reply(state.close_waiter, :ok)
      {:stop, :normal, %{state | close_waiter: nil}}
    else
      {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def format_status(status) when is_map(status),
    do: Map.merge(status, %{state: :redacted, message: :redacted, reason: :redacted, log: []})
end

defimpl Inspect, for: Synapse.Workspace.Fake.Server do
  def inspect(_state, _options), do: "#Synapse.Workspace.Fake.Server<redacted>"
end
