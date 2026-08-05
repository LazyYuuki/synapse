defmodule Synapse.Runtime.AgentTask do
  @moduledoc """
  Internal Agent-task ownership boundary for one Runtime run.

  The task derives exact Workspace Access from the validated Run Request, builds
  an OpenRequest with itself as owner, invokes the trusted Workspace opener,
  validates Agent Context, and reports readiness before calling Agent Runner.
  Request, prompt, cwd, Options, Handle, and callbacks remain in this task closure
  rather than RunServer state.

  Workspace opening is synchronously blocking and deliberately has no Runtime
  timeout. Request cwd is only an open input; real Workspace canonicalizes and
  authenticates the root. A custom opener is trusted to honor the supplied owner.

  `run/6` is exported only for the closure installed by `Synapse.Runtime`; it is
  intentionally `@doc false` because callers must not bypass RunServer startup,
  authority allocation, or terminal gating.
  """

  alias Synapse.Agent.{Context, Error, Result, Runner}
  alias Synapse.Run.Request
  alias Synapse.Runtime.{Options, RunServer}
  alias Synapse.Runtime.RunServer.Message
  alias Synapse.Workspace
  alias Synapse.Workspace.{Access, Handle, OpenRequest}

  @typedoc "Whether explicit Workspace closure completed before task return."
  @type close_status :: :workspace_closed | :workspace_close_failed

  @typedoc "One bounded Agent task outcome retained by RunServer."
  @type outcome ::
          {:agent_finished, Synapse.Agent.result() | :agent_failed, close_status()}
          | :startup_aborted

  @doc false
  @spec run(pid(), reference(), Request.t(), Options.t(), reference(), reference()) :: outcome()
  def run(run_server, run_ref, request, options, cancel_ref, cancellation) do
    coordinator_monitor = Process.monitor(run_server)

    case prepare(run_server, run_ref, request, options, cancel_ref, cancellation) do
      {:ok, handle, context} ->
        report_ready_and_wait(
          run_server,
          coordinator_monitor,
          run_ref,
          request,
          handle,
          context
        )

      {:error, reason, backend} ->
        report_failure_and_wait(run_server, coordinator_monitor, run_ref, reason, backend)
    end
  end

  defp prepare(run_server, run_ref, request, options, cancel_ref, cancellation) do
    with true <- Request.valid?(request) or {:error, :runtime_unavailable},
         true <- Options.valid?(options) or {:error, :runtime_unavailable},
         {:ok, access} <- derive_access(request),
         {:ok, open_request} <- build_open_request(request, options, access),
         {:ok, handle} <- open_workspace(options.workspace_opener, open_request),
         :ok <- validate_handle(handle, open_request),
         {:ok, context} <-
           build_context(
             run_server,
             run_ref,
             handle,
             options,
             cancel_ref,
             cancellation
           ) do
      {:ok, handle, context}
    else
      {:error, {:invalid_handle, %Handle{} = handle}} ->
        safe_close(handle)
        {:error, :workspace_open_failed, backend_pid(handle)}

      {:error, {:invalid_context, %Handle{} = handle}} ->
        safe_close(handle)
        {:error, :runtime_unavailable, backend_pid(handle)}

      {:error, reason} when reason in [:workspace_open_failed, :runtime_unavailable] ->
        {:error, reason, nil}

      _invalid ->
        {:error, :workspace_open_failed, nil}
    end
  end

  defp derive_access(%Request{capabilities: capabilities}) do
    case Access.new(
           read: capabilities.fs_read,
           write: capabilities.fs_write,
           exec: capabilities.process_exec
         ) do
      {:ok, access} -> {:ok, access}
      {:error, _reason} -> {:error, :workspace_open_failed}
    end
  end

  defp build_open_request(request, options, access) do
    case OpenRequest.new(
           root: request.cwd,
           owner: self(),
           limits: options.workspace_limits,
           access: access
         ) do
      {:ok, open_request} -> {:ok, open_request}
      {:error, _reason} -> {:error, :workspace_open_failed}
    end
  end

  defp open_workspace(opener, open_request) do
    try do
      case opener.(open_request) do
        {:ok, %Handle{} = handle} -> {:ok, handle}
        _failure -> {:error, :workspace_open_failed}
      end
    rescue
      _exception -> {:error, :workspace_open_failed}
    catch
      _kind, _reason -> {:error, :workspace_open_failed}
    end
  end

  defp validate_handle(%Handle{} = handle, open_request) do
    if is_pid(handle.state) and handle.limits == open_request.limits and
         handle.access == open_request.access and
         Workspace.valid_handle?(handle),
       do: :ok,
       else: {:error, {:invalid_handle, handle}}
  end

  defp build_context(run_server, run_ref, handle, options, cancel_ref, cancellation) do
    worker = self()

    event_sink = fn event -> RunServer.emit_event(run_server, run_ref, worker, event) end
    cancelled? = fn -> cancelled?(cancellation) end

    case Context.new(
           provider: options.provider,
           workspace: handle,
           instructions: options.instructions,
           event_sink: event_sink,
           cancel_ref: cancel_ref,
           cancelled?: cancelled?,
           deadline: options.deadline,
           provider_activity_sink: nil,
           tool_activity_sink: nil,
           tool_limits: options.tool_limits,
           retry_delay: options.retry_delay
         ) do
      {:ok, context} -> {:ok, context}
      {:error, _reason} -> {:error, {:invalid_context, handle}}
    end
  end

  defp report_ready_and_wait(
         run_server,
         coordinator_monitor,
         run_ref,
         request,
         handle,
         context
       ) do
    {:ok, ready} = Message.ready(run_ref, self(), handle)
    send(run_server, ready)

    case await_start_control(run_server, coordinator_monitor, run_ref) do
      :accept ->
        terminal = invoke_runner(request, context)
        close_status = safe_close(handle)
        {:agent_finished, terminal, close_status}

      :abort ->
        safe_close(handle)
        :startup_aborted
    end
  end

  defp report_failure_and_wait(run_server, coordinator_monitor, run_ref, reason, backend) do
    {:ok, failure} = Message.ready_failed(run_ref, self(), reason, backend)
    send(run_server, failure)
    await_start_control(run_server, coordinator_monitor, run_ref)
    :startup_aborted
  end

  defp await_start_control(run_server, coordinator_monitor, run_ref) do
    receive do
      %Message{kind: :accept, run_ref: ^run_ref} ->
        Process.demonitor(coordinator_monitor, [:flush])
        :accept

      %Message{kind: :abort, run_ref: ^run_ref} ->
        Process.demonitor(coordinator_monitor, [:flush])
        :abort

      {:DOWN, ^coordinator_monitor, :process, ^run_server, _reason} ->
        :abort

      _unrelated ->
        await_start_control(run_server, coordinator_monitor, run_ref)
    end
  end

  defp invoke_runner(request, context) do
    try do
      normalize_terminal(Runner.run(request, context))
    rescue
      _exception -> :agent_failed
    catch
      _kind, _reason -> :agent_failed
    end
  end

  defp normalize_terminal({:ok, %Result{} = result} = terminal) do
    case Result.new(Map.from_struct(result)) do
      {:ok, _result} -> terminal
      {:error, _reason} -> :agent_failed
    end
  end

  defp normalize_terminal({:error, %Error{} = error} = terminal) do
    case Error.new(Map.from_struct(error)) do
      {:ok, _error} -> terminal
      {:error, _reason} -> :agent_failed
    end
  end

  defp normalize_terminal(_terminal), do: :agent_failed

  defp safe_close(handle) do
    try do
      if Workspace.close(handle) == :ok,
        do: :workspace_closed,
        else: :workspace_close_failed
    rescue
      _exception -> :workspace_close_failed
    catch
      _kind, _reason -> :workspace_close_failed
    end
  end

  defp cancelled?(cancellation) do
    :atomics.get(cancellation, 1) == 1
  rescue
    _exception -> true
  catch
    _kind, _reason -> true
  end

  defp backend_pid(%Handle{state: backend}) when is_pid(backend), do: backend
  defp backend_pid(_handle), do: nil
end
