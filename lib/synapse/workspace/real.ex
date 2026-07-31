defmodule Synapse.Workspace.Real do
  @moduledoc """
  The real host-backed Workspace implementation selected by `Workspace.open/1`.

  It opens and owns a canonical root, observes bounded UTF-8 files, returns
  workspace-scoped revisions, and routes admission through one temporary
  MutationServer. Revision-checked whole-file creation, replacement, and exact
  edits commit atomically. Bounded project commands run through temporary linked
  workers and a MuonTrap-wrapped Port without blocking MutationServer callbacks.
  """

  @behaviour Synapse.Workspace.Backend

  alias Synapse.Workspace.{
    Error,
    Handle,
    MutationResult,
    MutationServer,
    OpenRequest,
    Platform,
    ProcessResult,
    Reader,
    ReadResult
  }

  @impl true
  @doc false
  def workspace_backend?, do: true

  @doc false
  @spec open(OpenRequest.t()) :: {:ok, Handle.t()} | {:error, Error.t()}
  def open(%OpenRequest{} = request) do
    with true <- Platform.supported?(),
         token <- make_ref(),
         {:ok, owner} <- MutationServer.start(request, token) do
      {:ok,
       %Handle{
         backend: __MODULE__,
         state: owner,
         token: token,
         limits: request.limits,
         access: request.access
       }}
    else
      false ->
        open_error(:unsupported, :unsupported_platform, "Workspace platform is unsupported")

      {:error, :unsupported_filesystem} ->
        open_error(:unsupported, :unsupported_filesystem, "Workspace filesystem is unsupported")

      {:error, :invalid_root} ->
        open_error(:invalid, :invalid_root, "Workspace root is invalid")

      {:error, _reason} ->
        open_error(:unavailable, :backend_unavailable, "Workspace root owner failed")
    end
  end

  @impl true
  @doc false
  def close(%Handle{} = handle) do
    case MutationServer.close(handle.state, handle.token) do
      :ok -> :ok
      {:error, :invalid_handle} -> operation_error(:close, :invalid_handle, nil, nil)
    end
  end

  @impl true
  @doc false
  def valid_handle?(%Handle{} = handle),
    do:
      MutationServer.valid_handle?(
        handle.state,
        handle.token,
        handle.limits,
        handle.access
      )

  @impl true
  @doc false
  def read(handle, request, context) do
    case MutationServer.acquire(
           handle.state,
           handle.token,
           context.operation_id,
           :read,
           context
         ) do
      {:ok, lease} ->
        try do
          do_read(handle, request, context)
        after
          MutationServer.release(lease)
        end

      {:error, reason} ->
        operation_error(:read, reason, valid_relative(request.path, handle.limits), context)
    end
  end

  defp do_read(handle, request, context) do
    with {:ok, resolved} <-
           MutationServer.resolve(handle.state, handle.token, request.path, :file, false),
         {:ok, observation} <- Reader.read(resolved, request, context, handle.limits),
         {:ok, revision} <-
           MutationServer.confirm_revision(
             handle.state,
             handle.token,
             resolved.relative,
             observation.stat,
             observation.digest
           ),
         {:ok, result} <-
           ReadResult.new(
             %{
               path: resolved.relative,
               revision: revision,
               lines: observation.lines,
               next_line: observation.next_line,
               file_bytes: observation.file_bytes
             },
             handle.limits
           ),
         :ok <- Reader.complete(context) do
      {:ok, result}
    else
      {:error, reason} when is_atom(reason) ->
        operation_error(:read, reason, valid_relative(request.path, handle.limits), context)

      {:error, _validation} ->
        operation_error(:read, :io, valid_relative(request.path, handle.limits), context)
    end
  end

  @impl true
  @doc false
  def write(handle, request, context),
    do: file_mutation_operation(handle, request, context, :write)

  @impl true
  @doc false
  def edit(handle, request, context),
    do: file_mutation_operation(handle, request, context, :edit)

  @impl true
  @doc false
  def run(handle, spec, event_sink, context),
    do: process_operation(handle, spec, event_sink, context)

  defp open_error(kind, reason, message) do
    {:ok, error} =
      Error.new(
        kind: kind,
        reason: reason,
        operation: :open,
        message: message,
        outcome: :not_applicable
      )

    {:error, error}
  end

  defp operation_error(operation, reason, path, context, outcome_override \\ nil) do
    reason = public_reason(reason)
    {kind, outcome, message} = error_attributes(reason)
    outcome = outcome_override || outcome
    kind = if outcome == :unknown, do: :ambiguous, else: kind

    {:ok, error} =
      Error.new(
        kind: kind,
        reason: reason,
        operation: operation,
        message: message,
        operation_id: context && context.operation_id,
        path: path,
        outcome: outcome
      )

    {:error, error}
  end

  defp error_attributes(:not_implemented),
    do: {:unsupported, :not_applied, "Workspace operation is not implemented"}

  defp error_attributes(:not_found),
    do: {:not_found, :not_applied, "Workspace path was not found"}

  defp error_attributes(:invalid_root),
    do: {:unavailable, :not_applied, "Workspace root identity is unavailable"}

  defp error_attributes(:invalid_handle),
    do: {:unavailable, :not_applicable, "Workspace handle is invalid or closed"}

  defp error_attributes(:workspace_busy),
    do: {:conflict, :not_applied, "Workspace mutation owner is busy"}

  defp error_attributes(:expected_missing),
    do: {:conflict, :not_applied, "Workspace destination already exists"}

  defp error_attributes(:stale_revision),
    do: {:conflict, :not_applied, "Workspace file changed after it was read"}

  defp error_attributes(:no_match),
    do: {:conflict, :not_applied, "Workspace edit text was not found"}

  defp error_attributes(:multiple_matches),
    do: {:conflict, :not_applied, "Workspace edit text matched more than once"}

  defp error_attributes(:atomic_commit_failed),
    do: {:io, :not_applied, "Workspace atomic commit failed"}

  defp error_attributes(:durability_unknown),
    do: {:ambiguous, :unknown, "Workspace cannot confirm the committed file state"}

  defp error_attributes(:mutation_activity_failed),
    do: {:ambiguous, :unknown, "Workspace mutation committed but activity reporting failed"}

  defp error_attributes(:file_changed),
    do: {:conflict, :not_applied, "Workspace file changed while it was read"}

  defp error_attributes(:file_too_large),
    do: {:limit, :not_applied, "Workspace file exceeds the configured limit"}

  defp error_attributes(:cancelled),
    do: {:cancelled, :not_applicable, "Workspace operation was cancelled"}

  defp error_attributes(:deadline_elapsed),
    do: {:cancelled, :not_applicable, "Workspace operation deadline elapsed"}

  defp error_attributes(:inactivity_timeout),
    do: {:cancelled, :not_applicable, "Workspace process output became inactive"}

  defp error_attributes(:activity_sink_failed),
    do: {:unavailable, :not_applicable, "Workspace activity sink failed"}

  defp error_attributes(:executable_not_found),
    do: {:not_found, :not_applicable, "Workspace executable was not found"}

  defp error_attributes(:process_start_failed),
    do: {:unavailable, :not_applicable, "Workspace process could not start"}

  defp error_attributes(:event_sink_failed),
    do: {:unavailable, :not_applicable, "Workspace process event sink failed"}

  defp error_attributes(:runner_failed),
    do: {:unavailable, :not_applicable, "Workspace process runner failed"}

  defp error_attributes(:output_limit),
    do: {:limit, :not_applied, "Workspace process output limit was reached"}

  defp error_attributes(:access_denied),
    do: {:denied, :not_applicable, "Workspace file is not readable"}

  defp error_attributes(reason)
       when reason in [:symlink, :mount_crossing, :multiple_hard_links, :not_regular_file],
       do: {:denied, :not_applied, "Workspace path is not permitted"}

  defp error_attributes(:invalid_utf8),
    do: {:invalid, :not_applied, "Workspace file is not valid UTF-8"}

  defp error_attributes(reason)
       when reason in [
              :invalid_request,
              :absolute_path,
              :path_traversal,
              :path_too_long
            ],
       do: {:invalid, :not_applied, "Workspace path is invalid"}

  defp error_attributes(:io),
    do: {:io, :not_applied, "Workspace path validation failed"}

  defp error_attributes(_reason),
    do: {:io, :not_applied, "Workspace path validation failed"}

  defp public_reason(reason)
       when reason in [:empty_path, :nul_byte, :empty_component, :dot_component],
       do: :invalid_request

  defp public_reason(reason), do: reason

  defp valid_relative(path, limits) do
    case Synapse.Workspace.Path.normalize(path, limits.max_path_bytes, allow_dot: true) do
      {:ok, relative} -> relative
      {:error, _reason} -> nil
    end
  end

  defp mutation_kind(:write), do: :write
  defp mutation_kind(:edit), do: :edit

  defp file_mutation_operation(handle, request, context, operation) do
    case MutationServer.acquire(
           handle.state,
           handle.token,
           context.operation_id,
           mutation_kind(operation),
           context
         ) do
      {:ok, lease} ->
        try do
          case execute_file_mutation(operation, lease, request, context.operation_id) do
            {:ok, %MutationResult{} = result} ->
              case mutation_activity(context) do
                :ok ->
                  {:ok, result}

                {:error, :mutation_activity_failed} when not result.changed ->
                  operation_error(
                    operation,
                    :activity_sink_failed,
                    request.path,
                    context,
                    :not_applied
                  )

                {:error, :mutation_activity_failed} ->
                  operation_error(
                    operation,
                    :mutation_activity_failed,
                    request.path,
                    context,
                    :unknown
                  )
              end

            {:error, reason, outcome} ->
              operation_error(operation, reason, request.path, context, outcome)
          end
        after
          MutationServer.release(lease)
        end

      {:error, reason} ->
        outcome = if reason in [:cancelled, :deadline_elapsed], do: :not_applied, else: nil
        operation_error(operation, reason, request.path, context, outcome)
    end
  end

  defp execute_file_mutation(:write, lease, request, operation_id),
    do: MutationServer.write(lease, request, operation_id)

  defp execute_file_mutation(:edit, lease, request, operation_id),
    do: MutationServer.edit(lease, request, operation_id)

  defp process_operation(handle, spec, event_sink, context) do
    kind = if spec.mutation == :unknown, do: :unknown_process, else: :read_only_process

    case MutationServer.acquire(
           handle.state,
           handle.token,
           context.operation_id,
           kind,
           context
         ) do
      {:ok, lease} ->
        try do
          case MutationServer.run(lease, spec, event_sink, context) do
            {:ok, %ProcessResult{} = result} ->
              {:ok, result}

            {:error, reason, outcome} ->
              operation_error(:run, reason, spec.cwd, context, outcome)
          end
        after
          MutationServer.release(lease)
        end

      {:error, reason} ->
        outcome = if spec.mutation == :unknown, do: :not_applied, else: :not_applicable
        operation_error(:run, reason, spec.cwd, context, outcome)
    end
  end

  defp mutation_activity(%{activity_sink: nil}), do: :ok

  defp mutation_activity(%{activity_sink: sink} = context) do
    case sink.(context) do
      :ok -> :ok
      _invalid -> {:error, :mutation_activity_failed}
    end
  rescue
    _exception -> {:error, :mutation_activity_failed}
  catch
    _kind, _reason -> {:error, :mutation_activity_failed}
  end
end

# Owns root/revision state and every in-VM mutation/read lease for one handle.
defmodule Synapse.Workspace.MutationServer do
  @moduledoc false

  use GenServer

  alias Synapse.Workspace.{
    AtomicWriter,
    EditRequest,
    MutationLease,
    MutationResult,
    OpenRequest,
    OperationContext,
    Path,
    ProcessEnvironment,
    ProcessRunner,
    ProcessSpec,
    Reader,
    Revision,
    RevisionAlgorithm,
    Root,
    WriteRequest
  }

  @enforce_keys [
    :root,
    :owner,
    :owner_monitor,
    :token,
    :revision_key,
    :limits,
    :access,
    :active_lease,
    :readers,
    :mutation_worker,
    :process_environment,
    :process_workers,
    :closing,
    :close_waiter
  ]
  defstruct @enforce_keys

  @type lease_kind :: :read | :write | :edit | :read_only_process | :unknown_process

  @doc false
  def child_spec(argument) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [argument]},
      restart: :temporary,
      type: :worker
    }
  end

  @spec start_link({OpenRequest.t(), reference()}) :: GenServer.on_start()
  def start_link({request, token}), do: GenServer.start_link(__MODULE__, {request, token})

  @spec start(OpenRequest.t(), reference()) :: {:ok, pid()} | {:error, term()}
  def start(request, token), do: GenServer.start(__MODULE__, {request, token})

  @spec acquire(
          pid() | reference(),
          reference(),
          String.t(),
          lease_kind(),
          Synapse.Workspace.OperationContext.t() | nil
        ) ::
          {:ok, MutationLease.t()}
          | {:error,
             :workspace_busy | :invalid_handle | :invalid_request | :cancelled | :deadline_elapsed}
  def acquire(server, token, operation_id, kind, context \\ nil)

  def acquire(server, token, operation_id, kind, context) when is_pid(server) do
    case admission_interrupted?(context) do
      :ok ->
        request_reference = make_ref()
        server_monitor = Process.monitor(server)
        send(server, {:lease_request, self(), request_reference, token, operation_id, kind})

        await_admission(
          server,
          server_monitor,
          request_reference,
          operation_id,
          kind,
          context
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  def acquire(_server, _token, _operation_id, _kind, _context),
    do: {:error, :invalid_handle}

  @spec release(MutationLease.t()) :: :ok | {:error, :invalid_handle}
  def release(%MutationLease{} = lease) do
    result = GenServer.call(lease.server, {:release, lease.reference})
    Process.demonitor(lease.server_monitor, [:flush])
    result
  catch
    :exit, _reason ->
      Process.demonitor(lease.server_monitor, [:flush])
      {:error, :invalid_handle}
  end

  def release(_lease), do: {:error, :invalid_handle}

  @spec write(MutationLease.t(), WriteRequest.t(), String.t(), keyword()) ::
          {:ok, MutationResult.t()} | {:error, atom(), :not_applied | :unknown}
  def write(lease, request, operation_id, options \\ [])

  def write(%MutationLease{} = lease, %WriteRequest{} = request, operation_id, options) do
    GenServer.call(
      lease.server,
      {:write, lease.reference, request, operation_id, options},
      :infinity
    )
  catch
    :exit, _reason -> {:error, :durability_unknown, :unknown}
  end

  def write(_lease, _request, _operation_id, _options),
    do: {:error, :invalid_handle, :not_applied}

  @spec edit(MutationLease.t(), EditRequest.t(), String.t(), keyword()) ::
          {:ok, MutationResult.t()} | {:error, atom(), :not_applied | :unknown}
  def edit(lease, request, operation_id, options \\ [])

  def edit(%MutationLease{} = lease, %EditRequest{} = request, operation_id, options) do
    GenServer.call(
      lease.server,
      {:edit, lease.reference, request, operation_id, options},
      :infinity
    )
  catch
    :exit, _reason -> {:error, :durability_unknown, :unknown}
  end

  def edit(_lease, _request, _operation_id, _options),
    do: {:error, :invalid_handle, :not_applied}

  @spec run(MutationLease.t(), ProcessSpec.t(), function(), OperationContext.t()) ::
          {:ok, ProcessResult.t()} | {:error, atom(), :not_applicable | :not_applied | :unknown}
  def run(
        %MutationLease{} = lease,
        %ProcessSpec{} = spec,
        event_sink,
        %OperationContext{} = context
      )
      when is_function(event_sink, 1) do
    case admission_interrupted?(context) do
      :ok ->
        request_reference = make_ref()

        send(
          lease.server,
          {:process_run_request, self(), request_reference, lease.reference, spec, event_sink,
           context}
        )

        await_process_run(lease, spec, context, request_reference)

      {:error, reason} ->
        prestart_process_error(spec, reason)
    end
  end

  def run(_lease, _spec, _event_sink, _context),
    do: {:error, :invalid_handle, :not_applicable}

  defp await_process_run(lease, spec, context, request_reference) do
    receive do
      {:process_run_reply, server, ^request_reference, result} when server == lease.server ->
        result

      {:process_run_ready, server, ^request_reference} when server == lease.server ->
        case admission_interrupted?(context) do
          :ok ->
            send(
              lease.server,
              {:start_process_run, self(), lease.reference, request_reference}
            )

            await_active_process_run(lease, spec, context, request_reference)

          {:error, reason} ->
            send(lease.server, {:stop_process_run, self(), lease.reference, reason})
            await_stopped_process_run(lease, spec, request_reference)
        end

      {:cancel, cancel_reference}
      when is_reference(cancel_reference) and cancel_reference == context.cancel_ref ->
        send(
          lease.server,
          {:stop_process_run, self(), lease.reference, :cancelled}
        )

        await_stopped_process_run(lease, spec, request_reference)

      {:DOWN, monitor, :process, server, _reason}
      when monitor == lease.server_monitor and server == lease.server ->
        process_server_down(spec)
    end
  end

  defp await_active_process_run(lease, spec, context, request_reference) do
    receive do
      {:process_run_reply, server, ^request_reference, result} when server == lease.server ->
        result

      {:cancel, cancel_reference}
      when is_reference(cancel_reference) and cancel_reference == context.cancel_ref ->
        send(lease.server, {:stop_process_run, self(), lease.reference, :cancelled})
        await_stopped_process_run(lease, spec, request_reference)

      {:DOWN, monitor, :process, server, _reason}
      when monitor == lease.server_monitor and server == lease.server ->
        process_server_down(spec)
    end
  end

  defp await_stopped_process_run(lease, spec, request_reference) do
    receive do
      {:process_run_reply, server, ^request_reference, result} when server == lease.server ->
        result

      {:DOWN, monitor, :process, server, _reason}
      when monitor == lease.server_monitor and server == lease.server ->
        process_server_down(spec)
    end
  end

  defp process_server_down(%{mutation: :unknown}),
    do: {:error, :runner_failed, :unknown}

  defp process_server_down(%{mutation: :read_only}),
    do: {:error, :runner_failed, :not_applicable}

  defp prestart_process_error(%{mutation: :unknown}, reason),
    do: {:error, reason, :not_applied}

  defp prestart_process_error(%{mutation: :read_only}, reason),
    do: {:error, reason, :not_applicable}

  defp await_admission(
         server,
         server_monitor,
         request_reference,
         operation_id,
         kind,
         nil
       ) do
    receive do
      {:lease_reply, ^server, ^request_reference, result} ->
        admission_reply(
          result,
          server,
          server_monitor,
          request_reference,
          operation_id,
          kind
        )

      {:DOWN, ^server_monitor, :process, ^server, _reason} ->
        {:error, :invalid_handle}
    end
  end

  defp await_admission(
         server,
         server_monitor,
         request_reference,
         operation_id,
         kind,
         %OperationContext{deadline: :infinity} = context
       ) do
    receive do
      {:lease_reply, ^server, ^request_reference, result} ->
        admission_reply(
          result,
          server,
          server_monitor,
          request_reference,
          operation_id,
          kind
        )

      {:cancel, cancel_reference}
      when is_reference(cancel_reference) and cancel_reference == context.cancel_ref ->
        withdraw_admission(
          server,
          server_monitor,
          request_reference,
          :cancelled
        )

      {:DOWN, ^server_monitor, :process, ^server, _reason} ->
        {:error, :invalid_handle}
    end
  end

  defp await_admission(
         server,
         server_monitor,
         request_reference,
         operation_id,
         kind,
         %OperationContext{} = context
       ) do
    timeout = deadline_wait(context.deadline)

    receive do
      {:lease_reply, ^server, ^request_reference, result} ->
        if System.monotonic_time(:millisecond) >= context.deadline do
          withdraw_admission(
            server,
            server_monitor,
            request_reference,
            :deadline_elapsed
          )
        else
          admission_reply(
            result,
            server,
            server_monitor,
            request_reference,
            operation_id,
            kind
          )
        end

      {:cancel, cancel_reference}
      when is_reference(cancel_reference) and cancel_reference == context.cancel_ref ->
        withdraw_admission(
          server,
          server_monitor,
          request_reference,
          :cancelled
        )

      {:DOWN, ^server_monitor, :process, ^server, _reason} ->
        {:error, :invalid_handle}
    after
      timeout ->
        if System.monotonic_time(:millisecond) >= context.deadline do
          withdraw_admission(
            server,
            server_monitor,
            request_reference,
            :deadline_elapsed
          )
        else
          await_admission(
            server,
            server_monitor,
            request_reference,
            operation_id,
            kind,
            context
          )
        end
    end
  end

  defp admission_reply(
         {:ok, lease_reference},
         server,
         server_monitor,
         _request_reference,
         operation_id,
         kind
       ) do
    {:ok,
     %MutationLease{
       server: server,
       server_monitor: server_monitor,
       reference: lease_reference,
       holder: self(),
       operation_id: operation_id,
       kind: kind
     }}
  end

  defp admission_reply(
         {:error, reason},
         _server,
         server_monitor,
         _request_reference,
         _operation_id,
         _kind
       ) do
    Process.demonitor(server_monitor, [:flush])
    {:error, reason}
  end

  defp withdraw_admission(server, server_monitor, request_reference, reason) do
    send(server, {:cancel_lease_request, self(), request_reference})
    await_withdrawal(server, server_monitor, request_reference, reason)
  end

  defp await_withdrawal(server, server_monitor, request_reference, reason) do
    receive do
      {:lease_cancelled, ^server, ^request_reference} ->
        Process.demonitor(server_monitor, [:flush])
        {:error, reason}

      {:lease_reply, ^server, ^request_reference, _result} ->
        await_withdrawal(server, server_monitor, request_reference, reason)

      {:DOWN, ^server_monitor, :process, ^server, _server_reason} ->
        {:error, reason}
    end
  end

  defp admission_interrupted?(nil), do: :ok

  defp admission_interrupted?(%OperationContext{} = context) do
    cond do
      context.deadline != :infinity and
          System.monotonic_time(:millisecond) >= context.deadline ->
        {:error, :deadline_elapsed}

      admission_cancelled?(context.cancel_ref) ->
        {:error, :cancelled}

      true ->
        :ok
    end
  end

  defp admission_cancelled?(nil), do: false

  defp admission_cancelled?(cancel_ref) do
    receive do
      {:cancel, ^cancel_ref} -> true
    after
      0 -> false
    end
  end

  defp deadline_wait(deadline) do
    deadline
    |> Kernel.-(System.monotonic_time(:millisecond))
    |> max(0)
    |> min(4_294_967_295)
  end

  @spec valid_handle?(pid() | reference(), reference(), term(), term()) :: boolean()
  def valid_handle?(owner, token, limits, access) when is_pid(owner) do
    GenServer.call(owner, {:valid_handle, token, limits, access})
  catch
    :exit, _reason -> false
  end

  def valid_handle?(_owner, _token, _limits, _access), do: false

  @spec close(pid() | reference(), reference()) :: :ok | {:error, :invalid_handle}
  def close(owner, token) when is_pid(owner) do
    case mutation_server_identity(owner) do
      :dead ->
        :ok

      :invalid ->
        {:error, :invalid_handle}

      :valid ->
        case GenServer.call(owner, {:close, token}, :infinity) do
          :closing -> await_server_close(owner)
          result -> result
        end
    end
  catch
    :exit, reason -> if closed_exit?(reason), do: :ok, else: {:error, :invalid_handle}
  end

  def close(_owner, _token), do: {:error, :invalid_handle}

  defp await_server_close(server) do
    monitor = Process.monitor(server)

    receive do
      {:DOWN, ^monitor, :process, ^server, _reason} -> :ok
    end
  end

  defp closed_exit?({:noproc, _call}), do: true
  defp closed_exit?({:normal, _call}), do: true
  defp closed_exit?({:shutdown, _call}), do: true
  defp closed_exit?(:noproc), do: true
  defp closed_exit?(_reason), do: false

  defp mutation_server_identity(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} ->
        if Keyword.get(dictionary, :"$initial_call") == {__MODULE__, :init, 1},
          do: :valid,
          else: :invalid

      nil ->
        :dead
    end
  end

  @spec resolve(pid() | reference(), reference(), String.t(), :file | :directory, boolean()) ::
          {:ok, Synapse.Workspace.Resolved.t()} | {:error, term()}
  def resolve(owner, token, path, expected_type, allow_missing?) when is_pid(owner) do
    GenServer.call(owner, {:resolve, token, path, expected_type, allow_missing?})
  catch
    :exit, _reason -> {:error, :invalid_handle}
  end

  def resolve(_owner, _token, _path, _expected_type, _allow_missing?),
    do: {:error, :invalid_handle}

  @spec confirm_revision(pid() | reference(), reference(), String.t(), File.Stat.t(), binary()) ::
          {:ok, Revision.t()} | {:error, :file_changed | :invalid_handle}
  def confirm_revision(owner, token, path, stat, digest) when is_pid(owner) do
    GenServer.call(owner, {:confirm_revision, token, path, stat, digest})
  catch
    :exit, _reason -> {:error, :invalid_handle}
  end

  def confirm_revision(_owner, _token, _path, _stat, _digest),
    do: {:error, :invalid_handle}

  @spec revision_matches?(
          pid() | reference(),
          reference(),
          String.t(),
          File.Stat.t(),
          binary(),
          Revision.t()
        ) :: boolean()
  def revision_matches?(owner, token, path, stat, digest, revision) when is_pid(owner) do
    GenServer.call(owner, {:revision_matches, token, path, stat, digest, revision})
  catch
    :exit, _reason -> false
  end

  def revision_matches?(_owner, _token, _path, _stat, _digest, _revision), do: false

  @impl true
  def init({request, token}) do
    with {:ok, root} <- Root.open(request.root, request.limits),
         {:ok, process_environment} <- ProcessEnvironment.open(request.limits, self()) do
      Process.flag(:trap_exit, true)
      owner_monitor = Process.monitor(request.owner)
      revision_key = :crypto.strong_rand_bytes(32)

      {:ok,
       %__MODULE__{
         root: root,
         owner: request.owner,
         owner_monitor: owner_monitor,
         token: token,
         revision_key: revision_key,
         limits: request.limits,
         access: request.access,
         active_lease: nil,
         readers: %{},
         mutation_worker: nil,
         process_environment: process_environment,
         process_workers: %{},
         closing: false,
         close_waiter: nil
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:close, token}, {closer, _tag} = from, %{token: token} = state) do
    if active_work?(state) and not caller_owns_only_idle_leases?(state, closer),
      do: request_close(from, state),
      else: {:stop, :normal, :ok, state}
  end

  def handle_call({:close, _token}, _from, state),
    do: {:reply, {:error, :invalid_handle}, state}

  def handle_call(
        {:valid_handle, token, limits, access},
        _from,
        %{token: token, limits: limits, access: access, closing: false} = state
      ),
      do: {:reply, true, state}

  def handle_call({:valid_handle, _token, _limits, _access}, _from, state),
    do: {:reply, false, state}

  def handle_call({:release, lease_reference}, {holder, _tag}, state) do
    case release_lease(state, lease_reference, holder) do
      {:ok, state} ->
        case maybe_finish_close(state) do
          {:noreply, state} -> {:reply, :ok, state}
          {:stop, reason, state} -> {:stop, reason, :ok, state}
        end

      :error ->
        {:reply, {:error, :invalid_handle}, state}
    end
  end

  def handle_call(
        {:write, lease_reference, request, operation_id, options},
        {holder, _tag} = from,
        %{
          active_lease: %{
            reference: lease_reference,
            holder: holder,
            operation_id: operation_id,
            kind: :write
          }
        } = state
      ) do
    case WriteRequest.new(Map.from_struct(request), state.limits) do
      {:ok, request} ->
        start_file_mutation(
          :write,
          request,
          operation_id,
          options,
          lease_reference,
          from,
          state
        )

      {:error, _validation} ->
        {:reply, {:error, :invalid_request, :not_applied}, state}
    end
  end

  def handle_call({:write, _lease_reference, _request, _operation_id, _options}, _from, state),
    do: {:reply, {:error, :invalid_handle, :not_applied}, state}

  def handle_call(
        {:edit, lease_reference, request, operation_id, options},
        {holder, _tag} = from,
        %{
          active_lease: %{
            reference: lease_reference,
            holder: holder,
            operation_id: operation_id,
            kind: :edit
          }
        } = state
      ) do
    case EditRequest.new(Map.from_struct(request), state.limits) do
      {:ok, request} ->
        start_file_mutation(
          :edit,
          request,
          operation_id,
          options,
          lease_reference,
          from,
          state
        )

      {:error, _validation} ->
        {:reply, {:error, :invalid_request, :not_applied}, state}
    end
  end

  def handle_call({:edit, _lease_reference, _request, _operation_id, _options}, _from, state),
    do: {:reply, {:error, :invalid_handle, :not_applied}, state}

  def handle_call(
        {:resolve, token, path, expected_type, allow_missing?},
        _from,
        %{token: token} = state
      ) do
    result =
      Path.resolve(
        state.root,
        path,
        state.limits.max_path_bytes,
        expected_type,
        allow_missing: allow_missing?
      )

    {:reply, result, state}
  end

  def handle_call({:resolve, _token, _path, _expected_type, _allow_missing?}, _from, state),
    do: {:reply, {:error, :invalid_handle}, state}

  def handle_call(
        {:confirm_revision, token, path, stat, digest},
        _from,
        %{token: token} = state
      ) do
    result =
      case Path.resolve(state.root, path, state.limits.max_path_bytes, :file) do
        {:ok, resolved} ->
          with true <- Reader.fingerprint(resolved.stat) == Reader.fingerprint(stat),
               {:ok, revision} <-
                 RevisionAlgorithm.calculate(
                   state.revision_key,
                   resolved.relative,
                   stat,
                   digest
                 ) do
            {:ok, revision}
          else
            _changed -> {:error, :file_changed}
          end

        {:error, :invalid_root} ->
          {:error, :invalid_root}

        {:error, _reason} ->
          {:error, :file_changed}
      end

    {:reply, result, state}
  end

  def handle_call({:confirm_revision, _token, _path, _stat, _digest}, _from, state),
    do: {:reply, {:error, :invalid_handle}, state}

  def handle_call(
        {:revision_matches, token, path, stat, digest, revision},
        _from,
        %{token: token} = state
      ) do
    matches? = RevisionAlgorithm.matches?(revision, state.revision_key, path, stat, digest)
    {:reply, matches?, state}
  end

  def handle_call(
        {:revision_matches, _token, _path, _stat, _digest, _revision},
        _from,
        state
      ),
      do: {:reply, false, state}

  @impl true
  def handle_info(
        {:process_run_request, holder, request_reference, lease_reference, spec, event_sink,
         context},
        state
      ) do
    operation_id = context.operation_id

    with {:ok, spec} <- ProcessSpec.new(Map.from_struct(spec), state.limits),
         {:ok, lease_scope} <-
           process_lease_scope(state, spec, lease_reference, holder, operation_id),
         {:ok, resolved} <-
           Path.resolve(state.root, spec.cwd, state.limits.max_path_bytes, :directory),
         {:ok, environment} <-
           ProcessEnvironment.build(state.process_environment, state.limits) do
      start_process_worker(
        spec,
        resolved.absolute,
        environment,
        event_sink,
        operation_id,
        context.deadline,
        lease_reference,
        lease_scope,
        {holder, request_reference},
        state
      )
    else
      {:error, reason} when is_atom(reason) ->
        outcome = if spec.mutation == :unknown, do: :not_applied, else: :not_applicable
        send(holder, {:process_run_reply, self(), request_reference, {:error, reason, outcome}})
        {:noreply, state}

      {:error, _validation} ->
        outcome = if spec.mutation == :unknown, do: :not_applied, else: :not_applicable

        send(
          holder,
          {:process_run_reply, self(), request_reference, {:error, :invalid_request, outcome}}
        )

        {:noreply, state}
    end
  end

  def handle_info(
        {:lease_request, holder, request_reference, token, operation_id, kind},
        %{token: token} = state
      ) do
    {result, state} = admit_lease(state, request_reference, operation_id, kind, holder)
    send(holder, {:lease_reply, self(), request_reference, result})
    {:noreply, state}
  end

  def handle_info(
        {:lease_request, holder, request_reference, _token, _operation_id, _kind},
        state
      ) do
    send(holder, {:lease_reply, self(), request_reference, {:error, :invalid_handle}})
    {:noreply, state}
  end

  def handle_info({:cancel_lease_request, holder, request_reference}, state) do
    state = release_request(state, request_reference, holder)
    send(holder, {:lease_cancelled, self(), request_reference})
    {:noreply, state}
  end

  def handle_info(
        {:start_process_run, holder, lease_reference, request_reference},
        state
      ) do
    case Enum.find(state.process_workers, fn {_reference, worker} ->
           worker.reply_to == {holder, request_reference} and
             worker.lease_reference == lease_reference and not worker.started
         end) do
      {reference, worker} ->
        send(worker.pid, {:run_process, reference})

        process_workers =
          Map.put(state.process_workers, reference, %{worker | started: true})

        {:noreply, %{state | process_workers: process_workers}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:stop_process_run, holder, lease_reference, reason}, state)
      when reason in [:cancelled, :deadline_elapsed, :coordinator_down] do
    Enum.each(state.process_workers, fn {_reference, worker} ->
      lease = process_worker_lease(state, worker)

      if (worker.lease_reference == lease_reference and lease) && lease.holder == holder do
        stop_process_worker(worker, reason)
      end
    end)

    {:noreply, state}
  end

  def handle_info(
        {:file_mutation_result, reference, worker, result},
        %{
          mutation_worker: %{
            reference: reference,
            pid: worker,
            monitor: monitor,
            from: from
          }
        } = state
      ) do
    Process.demonitor(monitor, [:flush])
    GenServer.reply(from, result)
    finish_file_mutation(state)
  end

  def handle_info(
        {:DOWN, monitor, :process, worker, _reason},
        %{
          mutation_worker: %{
            pid: worker,
            monitor: monitor,
            from: from
          }
        } = state
      ) do
    GenServer.reply(from, {:error, :durability_unknown, :unknown})
    finish_file_mutation(state)
  end

  def handle_info(
        {:process_worker_result, reference, worker, result},
        state
      ) do
    case state.process_workers[reference] do
      %{pid: ^worker, monitor: monitor} = entry ->
        Process.demonitor(monitor, [:flush])
        reply_process_run(entry, result)
        finish_process_worker(state, reference)

      _missing_or_mismatched ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:DOWN, monitor, :process, owner, _reason},
        %{
          owner_monitor: monitor,
          owner: owner
        } = state
      ),
      do: {:stop, :normal, state}

  def handle_info(
        {:DOWN, monitor, :process, worker, _reason},
        state
      ) do
    case Enum.find(state.process_workers, fn {_reference, entry} ->
           entry.pid == worker and entry.monitor == monitor
         end) do
      {reference, entry} ->
        {:stop, {:process_worker_down, entry.mutation, reference}, state}

      nil ->
        state
        |> release_or_mark_holder(monitor, worker)
        |> maybe_finish_close()
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    if state.mutation_worker, do: Process.exit(state.mutation_worker.pid, :shutdown)

    Enum.each(state.process_workers, fn {_reference, worker} ->
      Process.exit(worker.pid, :shutdown)
    end)

    notify_revoked(state.active_lease, reason)
    Enum.each(state.readers, fn {_reference, reader} -> notify_revoked(reader, reason) end)

    delay_ms =
      if map_size(state.process_workers) > 0,
        do: 2 * state.limits.kill_grace_ms + 500,
        else: 0

    ProcessEnvironment.close(state.process_environment, delay_ms)
    :ok
  end

  @impl true
  def format_status(status) when is_map(status) do
    Map.merge(status, %{state: :redacted, message: :redacted, reason: :redacted, log: []})
  end

  @impl true
  def format_status(_reason, [_process_dictionary, _state]), do: [data: [{~c"State", :redacted}]]

  defp admit_lease(state, request_reference, operation_id, kind, holder) do
    cond do
      state.closing ->
        {{:error, :invalid_handle}, state}

      not valid_admission_data?(state, operation_id, kind, holder) ->
        {{:error, :invalid_request}, state}

      operation_id_active?(state, operation_id) or not lease_available?(state, kind) ->
        {{:error, :workspace_busy}, state}

      true ->
        {reference, state} =
          grant_lease(state, request_reference, operation_id, kind, holder)

        {{:ok, reference}, state}
    end
  end

  defp valid_admission_data?(state, operation_id, kind, holder) do
    Synapse.Workspace.Validation.bounded_string?(
      operation_id,
      state.limits.max_operation_id_bytes,
      false
    ) and kind in [:read, :write, :edit, :read_only_process, :unknown_process] and
      Process.alive?(holder) and
      admission_access?(state.access, kind)
  end

  defp admission_access?(access, :read), do: Synapse.Workspace.Access.allows?(access, :read)

  defp admission_access?(access, kind) when kind in [:write, :edit],
    do: Synapse.Workspace.Access.allows?(access, :write)

  defp admission_access?(access, kind) when kind in [:read_only_process, :unknown_process],
    do: Synapse.Workspace.Access.allows?(access, :exec)

  defp operation_id_active?(state, operation_id) do
    match?(%{operation_id: ^operation_id}, state.active_lease) or
      Enum.any?(state.readers, fn {_reference, reader} ->
        reader.operation_id == operation_id
      end)
  end

  defp lease_available?(%{active_lease: %{kind: :unknown_process}}, kind)
       when kind in [:read, :read_only_process],
       do: false

  defp lease_available?(state, kind) when kind in [:read, :read_only_process],
    do: map_size(state.readers) < state.limits.max_concurrent_operations

  defp lease_available?(%{active_lease: nil, readers: readers}, :unknown_process),
    do: map_size(readers) == 0

  defp lease_available?(%{active_lease: nil}, kind) when kind in [:write, :edit], do: true
  defp lease_available?(_state, _kind), do: false

  defp grant_lease(state, request_reference, operation_id, kind, holder) do
    reference = make_ref()
    monitor = Process.monitor(holder)

    entry = %{
      reference: reference,
      request_reference: request_reference,
      holder: holder,
      monitor: monitor,
      operation_id: operation_id,
      kind: kind
    }

    state =
      if kind in [:read, :read_only_process],
        do: %{state | readers: Map.put(state.readers, reference, entry)},
        else: %{state | active_lease: entry}

    {reference, state}
  end

  defp start_file_mutation(
         operation,
         request,
         operation_id,
         options,
         lease_reference,
         from,
         state
       ) do
    server = self()
    reference = make_ref()

    worker =
      spawn_link(fn ->
        receive do
          {:run_file_mutation, ^reference} -> :ok
        end

        result =
          case operation do
            :write ->
              AtomicWriter.write(
                state.root,
                state.revision_key,
                state.limits,
                request,
                operation_id,
                options
              )

            :edit ->
              AtomicWriter.edit(
                state.root,
                state.revision_key,
                state.limits,
                request,
                operation_id,
                options
              )
          end

        send(server, {:file_mutation_result, reference, self(), result})
      end)

    monitor = Process.monitor(worker)
    send(worker, {:run_file_mutation, reference})

    mutation_worker = %{
      reference: reference,
      pid: worker,
      monitor: monitor,
      from: from,
      lease_reference: lease_reference,
      holder_dead: false
    }

    {:noreply, %{state | mutation_worker: mutation_worker}}
  end

  defp process_lease_scope(state, %{mutation: :unknown}, reference, holder, operation_id) do
    if match?(
         %{
           reference: ^reference,
           holder: ^holder,
           operation_id: ^operation_id,
           kind: :unknown_process
         },
         state.active_lease
       ),
       do: {:ok, :active},
       else: {:error, :invalid_handle}
  end

  defp process_lease_scope(state, %{mutation: :read_only}, reference, holder, operation_id) do
    if match?(
         %{
           holder: ^holder,
           operation_id: ^operation_id,
           kind: :read_only_process
         },
         state.readers[reference]
       ),
       do: {:ok, :reader},
       else: {:error, :invalid_handle}
  end

  defp start_process_worker(
         spec,
         cwd,
         environment,
         event_sink,
         operation_id,
         context_deadline,
         lease_reference,
         lease_scope,
         reply_to,
         state
       ) do
    server = self()
    reference = make_ref()

    worker =
      spawn_link(fn ->
        result =
          receive do
            {:run_process, ^reference} ->
              ProcessRunner.run(
                cwd,
                environment,
                spec,
                event_sink,
                operation_id,
                state.limits,
                context_deadline
              )

            {:abort_process, result} ->
              result
          end

        send(server, {:process_worker_result, reference, self(), result})
      end)

    monitor = Process.monitor(worker)

    entry = %{
      pid: worker,
      monitor: monitor,
      reply_to: reply_to,
      lease_reference: lease_reference,
      lease_scope: lease_scope,
      mutation: spec.mutation,
      started: false,
      holder_dead: false
    }

    send(elem(reply_to, 0), {:process_run_ready, self(), elem(reply_to, 1)})

    {:noreply, %{state | process_workers: Map.put(state.process_workers, reference, entry)}}
  end

  defp stop_process_worker(%{started: true} = worker, reason),
    do: send(worker.pid, {:stop_process, reason})

  defp stop_process_worker(%{started: false} = worker, reason),
    do: send(worker.pid, {:abort_process, prestart_worker_result(worker.mutation, reason)})

  defp prestart_worker_result(:unknown, reason), do: {:error, reason, :not_applied}
  defp prestart_worker_result(:read_only, reason), do: {:error, reason, :not_applicable}

  defp release_lease(state, reference, holder) do
    cond do
      match?(%{reference: ^reference, holder: ^holder}, state.active_lease) ->
        Process.demonitor(state.active_lease.monitor, [:flush])
        {:ok, %{state | active_lease: nil}}

      match?(%{holder: ^holder}, state.readers[reference]) ->
        Process.demonitor(state.readers[reference].monitor, [:flush])
        {:ok, %{state | readers: Map.delete(state.readers, reference)}}

      true ->
        :error
    end
  end

  defp finish_file_mutation(state) do
    active_lease =
      if state.mutation_worker.holder_dead do
        Process.demonitor(state.active_lease.monitor, [:flush])
        nil
      else
        state.active_lease
      end

    state = %{state | active_lease: active_lease, mutation_worker: nil}

    maybe_finish_close(state)
  end

  defp finish_process_worker(state, reference) do
    worker = state.process_workers[reference]

    state =
      if worker.holder_dead do
        release_worker_lease(state, worker)
      else
        state
      end

    state = %{state | process_workers: Map.delete(state.process_workers, reference)}
    maybe_finish_close(state)
  end

  defp reply_process_run(%{reply_to: {holder, request_reference}}, result),
    do: send(holder, {:process_run_reply, self(), request_reference, result})

  defp release_worker_lease(state, %{lease_scope: :active}) do
    Process.demonitor(state.active_lease.monitor, [:flush])
    %{state | active_lease: nil}
  end

  defp release_worker_lease(state, %{lease_scope: :reader, lease_reference: reference}) do
    Process.demonitor(state.readers[reference].monitor, [:flush])
    %{state | readers: Map.delete(state.readers, reference)}
  end

  defp maybe_finish_close(state) do
    if not is_nil(state.close_waiter) and not active_work?(state) do
      # Deferred close callers observe the server's normal DOWN. Their
      # MutationServer.close/2 catch converts that post-terminate exit to :ok.
      GenServer.reply(state.close_waiter, :ok)
      {:stop, :normal, %{state | close_waiter: nil}}
    else
      {:noreply, state}
    end
  end

  defp request_close(_from, %{closing: true} = state), do: {:reply, :closing, state}

  defp request_close(from, state),
    do: {:noreply, %{state | closing: true, close_waiter: from}}

  defp active_work?(state) do
    not is_nil(state.active_lease) or map_size(state.readers) > 0 or
      not is_nil(state.mutation_worker) or map_size(state.process_workers) > 0
  end

  defp caller_owns_only_idle_leases?(state, closer) do
    is_nil(state.mutation_worker) and map_size(state.process_workers) == 0 and
      (is_nil(state.active_lease) or state.active_lease.holder == closer) and
      Enum.all?(state.readers, fn {_reference, reader} -> reader.holder == closer end)
  end

  defp release_or_mark_holder(
         %{
           active_lease: %{
             reference: lease_reference,
             monitor: monitor,
             holder: holder
           },
           mutation_worker:
             %{
               lease_reference: lease_reference
             } = worker
         } = state,
         monitor,
         holder
       ) do
    %{state | mutation_worker: %{worker | holder_dead: true}}
  end

  defp release_or_mark_holder(state, monitor, holder) do
    case Enum.find(state.process_workers, fn {_reference, worker} ->
           lease = process_worker_lease(state, worker)
           lease && lease.monitor == monitor && lease.holder == holder
         end) do
      {reference, worker} ->
        stop_process_worker(worker, :coordinator_down)

        %{
          state
          | process_workers:
              Map.put(state.process_workers, reference, %{worker | holder_dead: true})
        }

      nil ->
        release_holder(state, monitor, holder)
    end
  end

  defp process_worker_lease(state, %{lease_scope: :active}), do: state.active_lease

  defp process_worker_lease(state, %{lease_scope: :reader, lease_reference: reference}),
    do: state.readers[reference]

  defp release_holder(state, monitor, holder) do
    active_lease =
      case state.active_lease do
        %{monitor: ^monitor, holder: ^holder} -> nil
        lease -> lease
      end

    readers =
      Map.reject(state.readers, fn {_reference, reader} ->
        reader.monitor == monitor and reader.holder == holder
      end)

    %{state | active_lease: active_lease, readers: readers}
  end

  defp release_request(state, request_reference, holder) do
    cond do
      match?(%{request_reference: ^request_reference, holder: ^holder}, state.active_lease) ->
        Process.demonitor(state.active_lease.monitor, [:flush])
        %{state | active_lease: nil}

      reader =
          Enum.find_value(state.readers, fn {reference, reader} ->
            if reader.request_reference == request_reference and reader.holder == holder,
              do: {reference, reader}
          end) ->
        {reference, reader} = reader
        Process.demonitor(reader.monitor, [:flush])
        %{state | readers: Map.delete(state.readers, reference)}

      true ->
        state
    end
  end

  defp notify_revoked(nil, _reason), do: :ok

  defp notify_revoked(lease, reason),
    do:
      send(
        lease.holder,
        {:workspace_lease_revoked, self(), lease.reference, reason}
      )
end

defimpl Inspect, for: Synapse.Workspace.MutationServer do
  def inspect(_state, _options), do: "#Synapse.Workspace.MutationServer<redacted>"
end
