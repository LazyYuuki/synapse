# Internal bounded coordinator for one guarded MuonTrap command.
defmodule Synapse.Workspace.ProcessRunner do
  @moduledoc false

  alias Synapse.Workspace.{Limits, ProcessResult, ProcessSpec}
  alias Synapse.Workspace.ProcessEvent.{Output, Started}

  @env_executable "/usr/bin/env"
  @shell_executable "/bin/sh"
  @launcher "exec 0</dev/null; unset PWD _; exec \"$@\""

  @type outcome :: :not_applicable | :not_applied | :unknown

  @spec run(
          String.t(),
          keyword(String.t()),
          ProcessSpec.t(),
          (Synapse.Workspace.ProcessEvent.t() -> :ok),
          String.t(),
          Limits.t(),
          :infinity | integer()
        ) :: {:ok, ProcessResult.t()} | {:error, atom(), outcome()}
  def run(cwd, environment, spec, event_sink, operation_id, limits, context_deadline) do
    started_at = now_ms()
    coordinator = self()
    reference = make_ref()
    guard = spawn(fn -> port_guard(coordinator) end)
    Process.put(:synapse_process_port_guard, guard)

    worker =
      spawn(fn ->
        coordinator_monitor = Process.monitor(coordinator)

        progress = fn state ->
          send(coordinator, {:process_runner_progress, reference, self(), state})
        end

        emit_event = fn event, state ->
          emit_to_coordinator(
            coordinator,
            coordinator_monitor,
            reference,
            event,
            state
          )
        end

        result =
          port_run(
            cwd,
            environment,
            spec,
            operation_id,
            limits,
            started_at,
            coordinator,
            coordinator_monitor,
            guard,
            progress,
            emit_event
          )

        send(coordinator, {:process_runner_result, reference, self(), result, now_ms()})
      end)

    monitor = Process.monitor(worker)
    deadline = effective_deadline(started_at + spec.timeout_ms, context_deadline)

    await_initial_state(
      worker,
      monitor,
      reference,
      spec,
      operation_id,
      limits,
      started_at,
      deadline,
      started_at,
      event_sink
    )
  end

  defp await_initial_state(
         worker,
         monitor,
         reference,
         spec,
         operation_id,
         limits,
         started_at,
         deadline,
         last_activity_at,
         event_sink
       ) do
    {remaining_ms, timeout_reason} = next_timeout(deadline, last_activity_at, spec)

    receive do
      {:process_runner_progress, ^reference, ^worker, state} ->
        await_worker(
          worker,
          monitor,
          reference,
          spec,
          operation_id,
          limits,
          started_at,
          deadline,
          state,
          last_activity_at,
          event_sink
        )

      {:process_runner_result, ^reference, ^worker, result, _terminal_at} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^worker, _reason} ->
        case await_late_runner_result(reference, worker) do
          {:ok, result, _terminal_at} -> result
          :error -> runner_down_result(spec, limits, nil)
        end

      {:stop_process, reason} when reason in [:cancelled, :coordinator_down] ->
        await_started_stop(
          reason,
          worker,
          monitor,
          reference,
          spec,
          operation_id,
          limits,
          started_at
        )
    after
      remaining_ms ->
        await_started_stop(
          timeout_reason,
          worker,
          monitor,
          reference,
          spec,
          operation_id,
          limits,
          started_at
        )
    end
  end

  defp await_started_stop(
         reason,
         worker,
         monitor,
         reference,
         spec,
         operation_id,
         limits,
         started_at
       ) do
    receive do
      {:process_runner_progress, ^reference, ^worker, state} ->
        force_stop(
          reason,
          worker,
          monitor,
          spec,
          operation_id,
          limits,
          started_at,
          state
        )

      {:process_runner_result, ^reference, ^worker, result, _terminal_at} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^worker, _reason} ->
        case await_late_runner_result(reference, worker) do
          {:ok, result, _terminal_at} -> result
          :error -> runner_down_result(spec, limits, nil)
        end
    after
      limits.kill_grace_ms + 500 ->
        force_stop(
          reason,
          worker,
          monitor,
          spec,
          operation_id,
          limits,
          started_at,
          nil
        )
    end
  end

  defp await_worker(
         worker,
         monitor,
         reference,
         spec,
         operation_id,
         limits,
         started_at,
         deadline,
         latest_state,
         last_activity_at,
         event_sink
       ) do
    {remaining_ms, timeout_reason} = next_timeout(deadline, last_activity_at, spec)

    receive do
      {:process_runner_progress, ^reference, ^worker, state} ->
        await_worker(
          worker,
          monitor,
          reference,
          spec,
          operation_id,
          limits,
          started_at,
          deadline,
          state,
          last_activity_at,
          event_sink
        )

      {:process_runner_event, ^reference, ^worker, event, state, event_reference} ->
        handle_process_event(
          worker,
          monitor,
          reference,
          event_reference,
          event,
          state,
          spec,
          operation_id,
          limits,
          started_at,
          deadline,
          latest_state,
          last_activity_at,
          event_sink
        )

      {:process_runner_result, ^reference, ^worker, result, terminal_at} ->
        case timeout_at(terminal_at, deadline, last_activity_at, spec) do
          :ok ->
            Process.demonitor(monitor, [:flush])
            result

          {:timeout, reason} ->
            force_stop(
              reason,
              worker,
              monitor,
              spec,
              operation_id,
              limits,
              started_at,
              latest_state
            )
        end

      {:DOWN, ^monitor, :process, ^worker, _reason} ->
        case await_late_runner_result(reference, worker) do
          {:ok, result, terminal_at} ->
            case timeout_at(terminal_at, deadline, last_activity_at, spec) do
              :ok ->
                result

              {:timeout, reason} ->
                case await_helper_cleanup(latest_state, limits.kill_grace_ms) do
                  :ok ->
                    interrupted_result(
                      reason,
                      spec,
                      operation_id,
                      limits,
                      started_at,
                      latest_state
                    )

                  :error ->
                    exit(:process_cleanup_unconfirmed)
                end
            end

          :error ->
            runner_down_result(spec, limits, latest_state)
        end

      {:stop_process, reason} when reason in [:cancelled, :coordinator_down] ->
        force_stop(
          reason,
          worker,
          monitor,
          spec,
          operation_id,
          limits,
          started_at,
          latest_state
        )
    after
      remaining_ms ->
        force_stop(
          timeout_reason,
          worker,
          monitor,
          spec,
          operation_id,
          limits,
          started_at,
          latest_state
        )
    end
  end

  defp handle_process_event(
         worker,
         monitor,
         reference,
         event_reference,
         event,
         state,
         spec,
         operation_id,
         limits,
         started_at,
         deadline,
         latest_state,
         last_activity_at,
         event_sink
       ) do
    coordinator = self()
    sink_reference = make_ref()

    sink_worker =
      spawn(fn ->
        result = emit(event_sink, event)

        send(
          coordinator,
          {:process_sink_result, sink_reference, self(), result, now_ms()}
        )
      end)

    _watchdog = spawn(fn -> watch_sink_worker(coordinator, sink_worker) end)
    sink_monitor = Process.monitor(sink_worker)
    {remaining_ms, timeout_reason} = next_timeout(deadline, last_activity_at, spec)

    receive do
      {:process_sink_result, ^sink_reference, ^sink_worker, result, accepted_at} ->
        Process.demonitor(sink_monitor, [:flush])

        case timeout_at(accepted_at, deadline, last_activity_at, spec) do
          :ok ->
            send(worker, {:process_event_ack, event_reference, result})

            {next_state, next_activity_at} =
              if result == :ok do
                activity_at =
                  if match?(%Output{}, event), do: accepted_at, else: last_activity_at

                {state, activity_at}
              else
                {latest_state, last_activity_at}
              end

            await_worker(
              worker,
              monitor,
              reference,
              spec,
              operation_id,
              limits,
              started_at,
              deadline,
              next_state,
              next_activity_at,
              event_sink
            )

          {:timeout, reason} ->
            timeout_state = if result == :ok, do: state, else: latest_state

            force_stop(
              reason,
              worker,
              monitor,
              spec,
              operation_id,
              limits,
              started_at,
              timeout_state
            )
        end

      {:DOWN, ^sink_monitor, :process, ^sink_worker, _reason} ->
        send(worker, {:process_event_ack, event_reference, {:error, :event_sink_failed}})

        await_worker(
          worker,
          monitor,
          reference,
          spec,
          operation_id,
          limits,
          started_at,
          deadline,
          latest_state,
          last_activity_at,
          event_sink
        )

      {:DOWN, ^monitor, :process, ^worker, _reason} ->
        stop_sink_worker(sink_worker, sink_monitor)
        runner_down_result(spec, limits, latest_state)

      {:stop_process, reason} when reason in [:cancelled, :coordinator_down] ->
        stop_sink_worker(sink_worker, sink_monitor)

        force_stop(
          reason,
          worker,
          monitor,
          spec,
          operation_id,
          limits,
          started_at,
          latest_state
        )
    after
      remaining_ms ->
        stop_sink_worker(sink_worker, sink_monitor)

        force_stop(
          timeout_reason,
          worker,
          monitor,
          spec,
          operation_id,
          limits,
          started_at,
          latest_state
        )
    end
  end

  defp stop_sink_worker(worker, monitor) do
    Process.exit(worker, :kill)
    await_worker_down(worker, monitor)
  end

  defp watch_sink_worker(coordinator, sink_worker) do
    coordinator_monitor = Process.monitor(coordinator)
    sink_monitor = Process.monitor(sink_worker)

    receive do
      {:DOWN, ^coordinator_monitor, :process, ^coordinator, _reason} ->
        Process.exit(sink_worker, :kill)

      {:DOWN, ^sink_monitor, :process, ^sink_worker, _reason} ->
        :ok
    end
  end

  defp force_stop(reason, worker, monitor, spec, operation_id, limits, started_at, state) do
    Process.exit(worker, :kill)
    await_worker_down(worker, monitor)

    case await_helper_cleanup(state, limits.kill_grace_ms) do
      :ok -> interrupted_result(reason, spec, operation_id, limits, started_at, state)
      :error -> exit(:process_cleanup_unconfirmed)
    end
  end

  defp runner_down_result(spec, limits, state) do
    case await_helper_cleanup(state, limits.kill_grace_ms) do
      :ok -> runner_error(spec.mutation, :runner_failed)
      :error -> exit(:process_cleanup_unconfirmed)
    end
  end

  defp await_late_runner_result(reference, worker) do
    receive do
      {:process_runner_result, ^reference, ^worker, result, terminal_at} ->
        {:ok, result, terminal_at}
    after
      10 -> :error
    end
  end

  defp next_timeout(deadline, last_activity_at, spec) do
    inactivity_deadline = last_activity_at + spec.inactivity_ms

    if inactivity_deadline < deadline do
      {max(inactivity_deadline - now_ms(), 0), :inactivity_timeout}
    else
      {max(deadline - now_ms(), 0), :deadline_elapsed}
    end
  end

  defp timeout_at(occurred_at, deadline, last_activity_at, spec) do
    inactivity_deadline = last_activity_at + spec.inactivity_ms

    cond do
      inactivity_deadline < deadline and occurred_at >= inactivity_deadline ->
        {:timeout, :inactivity_timeout}

      occurred_at >= deadline ->
        {:timeout, :deadline_elapsed}

      true ->
        :ok
    end
  end

  defp effective_deadline(spec_deadline, :infinity), do: spec_deadline

  defp effective_deadline(spec_deadline, context_deadline),
    do: min(spec_deadline, context_deadline)

  defp await_worker_down(worker, monitor) do
    receive do
      {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
    after
      1_000 -> Process.demonitor(monitor, [:flush])
    end
  end

  defp port_run(
         cwd,
         environment,
         spec,
         operation_id,
         limits,
         started_at,
         coordinator,
         coordinator_monitor,
         guard,
         progress,
         emit_event
       ) do
    with :ok <- executable_available(spec.executable),
         {:ok, options} <- port_options(cwd, environment, spec, limits),
         {:ok, port, helper_os_pid, guard_monitor} <- open_guarded_port(guard, options) do
      state = %{
        port: port,
        helper_os_pid: helper_os_pid,
        operation_id: operation_id,
        sequence: 0,
        output: [],
        retained_bytes: 0,
        observed_bytes: 0,
        truncated: false,
        started_at: started_at,
        coordinator: coordinator,
        coordinator_monitor: coordinator_monitor,
        guard: guard,
        guard_monitor: guard_monitor
      }

      run_open_port(state, spec, limits, progress, emit_event)
    else
      {:error, reason} -> prestart_error(spec.mutation, reason)
    end
  rescue
    _exception -> runner_error(spec.mutation, :process_start_failed)
  catch
    :exit, :process_cleanup_unconfirmed -> exit(:process_cleanup_unconfirmed)
    _kind, _reason -> runner_error(spec.mutation, :process_start_failed)
  end

  defp run_open_port(state, spec, limits, progress, emit_event) do
    progress.(state)

    case emit_event.(started_event(state.operation_id, limits), state) do
      :ok ->
        receive_port(state, spec, limits, progress, emit_event)

      {:error, reason} ->
        stop_with_error(state, spec, limits, reason)
    end
  rescue
    _exception -> stop_with_error(state, spec, limits, :runner_failed)
  catch
    :exit, :process_cleanup_unconfirmed -> exit(:process_cleanup_unconfirmed)
    _kind, _reason -> stop_with_error(state, spec, limits, :runner_failed)
  end

  defp stop_with_error(state, spec, limits, reason) do
    case stop_port(state, limits.kill_grace_ms) do
      :ok -> runner_error(spec.mutation, reason)
      :error -> exit(:process_cleanup_unconfirmed)
    end
  end

  defp receive_port(state, spec, limits, progress, emit_event) do
    receive do
      {port, {:data, data}} when port == state.port and is_binary(data) ->
        handle_data(state, data, spec, limits, progress, emit_event)

      {port, {:exit_status, status}} when port == state.port ->
        process_result(state, spec, limits, :exited, status, state.truncated)

      {:DOWN, monitor, :process, coordinator, _reason}
      when monitor == state.coordinator_monitor and coordinator == state.coordinator ->
        stop_with_error(state, spec, limits, :runner_failed)

      {:DOWN, monitor, :process, guard, _reason}
      when monitor == state.guard_monitor and guard == state.guard ->
        stop_with_error(state, spec, limits, :runner_failed)

      {:process_port_failed, guard} when guard == state.guard ->
        stop_with_error(state, spec, limits, :runner_failed)
    end
  end

  defp handle_data(state, data, spec, limits, progress, emit_event) do
    output_bytes = spec.max_output_bytes - state.retained_bytes
    event_slots = max(limits.max_process_events - 1 - state.sequence, 0)
    event_bytes = event_slots * limits.max_process_event_bytes
    accepted_bytes = Enum.min([byte_size(data), output_bytes, event_bytes])
    accepted = if accepted_bytes == 0, do: "", else: binary_part(data, 0, accepted_bytes)

    case emit_data(state, accepted, emit_event, limits) do
      {:ok, state} when accepted_bytes == byte_size(data) ->
        progress.(state)
        report_bytes_handled(state, byte_size(data))
        receive_port(state, spec, limits, progress, emit_event)

      {:ok, state} ->
        observed =
          min(
            state.observed_bytes + byte_size(data) - accepted_bytes,
            spec.max_output_bytes + limits.max_process_event_bytes
          )

        state = %{state | observed_bytes: observed, truncated: true}
        progress.(state)
        report_bytes_handled(state, byte_size(data))
        receive_port(state, spec, limits, progress, emit_event)

      {:error, reason} ->
        case stop_port(state, limits.kill_grace_ms) do
          :ok -> runner_error(spec.mutation, reason)
          :error -> exit(:process_cleanup_unconfirmed)
        end
    end
  end

  defp emit_data(state, "", _emit_event, _limits), do: {:ok, state}

  defp emit_data(state, data, emit_event, limits) do
    chunk_bytes = min(byte_size(data), limits.max_process_event_bytes)
    <<chunk::binary-size(^chunk_bytes), rest::binary>> = data
    sequence = state.sequence + 1

    candidate = %{
      state
      | sequence: sequence,
        output: [chunk | state.output],
        retained_bytes: state.retained_bytes + chunk_bytes,
        observed_bytes: state.observed_bytes + chunk_bytes
    }

    with {:ok, event} <-
           Output.new(
             operation_id: state.operation_id,
             sequence: sequence,
             data: :binary.copy(chunk)
           ),
         :ok <- emit_event.(event, candidate) do
      emit_data(candidate, rest, emit_event, limits)
    else
      {:error, reason} -> {:error, reason}
      _failure -> {:error, :event_sink_failed}
    end
  end

  defp emit_to_coordinator(
         coordinator,
         coordinator_monitor,
         reference,
         event,
         state
       ) do
    event_reference = make_ref()

    send(
      coordinator,
      {:process_runner_event, reference, self(), event, state, event_reference}
    )

    receive do
      {:process_event_ack, ^event_reference, result} ->
        result

      {:DOWN, ^coordinator_monitor, :process, ^coordinator, _reason} ->
        {:error, :runner_failed}
    end
  end

  defp process_result(state, spec, limits, termination, exit_code, truncated) do
    ProcessResult.new(
      %{
        operation_id: state.operation_id,
        termination: termination,
        exit_code: exit_code,
        output: retained_output(state),
        output_bytes: state.observed_bytes,
        truncated: truncated,
        elapsed_ms: elapsed(state.started_at, spec, limits)
      },
      limits
    )
  end

  defp interrupted_result(
         :cancelled,
         %{mutation: :read_only} = spec,
         _operation_id,
         limits,
         _started_at,
         state
       ),
       do: process_result(state, spec, limits, :cancelled, nil, false)

  defp interrupted_result(
         reason,
         %{mutation: :read_only} = spec,
         _operation_id,
         limits,
         _started_at,
         state
       )
       when reason in [:deadline_elapsed, :inactivity_timeout],
       do: process_result(state, spec, limits, :timed_out, nil, false)

  defp interrupted_result(
         :coordinator_down,
         %{mutation: :read_only},
         _operation_id,
         _limits,
         _started_at,
         _state
       ),
       do: {:error, :runner_failed, :not_applicable}

  defp interrupted_result(
         :cancelled,
         %{mutation: :unknown},
         _operation_id,
         _limits,
         _started_at,
         _state
       ),
       do: {:error, :cancelled, :unknown}

  defp interrupted_result(
         reason,
         %{mutation: :unknown},
         _operation_id,
         _limits,
         _started_at,
         _state
       )
       when reason in [:deadline_elapsed, :inactivity_timeout],
       do: {:error, reason, :unknown}

  defp interrupted_result(
         :coordinator_down,
         %{mutation: :unknown},
         _operation_id,
         _limits,
         _started_at,
         _state
       ),
       do: {:error, :runner_failed, :unknown}

  defp runner_error(:unknown, reason), do: {:error, reason, :unknown}
  defp runner_error(:read_only, reason), do: {:error, reason, :not_applicable}

  defp prestart_error(:unknown, reason), do: {:error, reason, :not_applied}
  defp prestart_error(:read_only, reason), do: {:error, reason, :not_applicable}

  defp retained_output(state),
    do: state.output |> Enum.reverse() |> IO.iodata_to_binary()

  defp started_event(operation_id, limits) do
    {:ok, event} = Started.new(%{operation_id: operation_id}, limits)
    event
  end

  defp emit(event_sink, event) do
    case event_sink.(event) do
      :ok -> :ok
      {:error, :activity_sink_failed} = error -> error
      _invalid -> {:error, :event_sink_failed}
    end
  rescue
    _exception -> {:error, :event_sink_failed}
  catch
    _kind, _reason -> {:error, :event_sink_failed}
  end

  defp executable_available(executable) do
    if System.find_executable(executable),
      do: :ok,
      else: {:error, :executable_not_found}
  end

  defp port_options(cwd, environment, spec, limits) do
    allowed = Enum.reject(environment, fn {_name, value} -> is_nil(value) end)

    launcher_arguments =
      ["-i"] ++
        Enum.map(allowed, fn {name, value} -> "#{name}=#{value}" end) ++
        [@shell_executable, "-c", @launcher, "synapse-launcher", spec.executable] ++
        spec.arguments

    options =
      MuonTrap.Options.validate(
        :cmd,
        @env_executable,
        launcher_arguments,
        cd: cwd,
        env: environment,
        stderr_to_stdout: true,
        stdio_window: limits.max_process_event_bytes,
        delay_to_sigkill: limits.kill_grace_ms
      )

    {:ok, MuonTrap.Port.port_options(options, ["--capture-output"])}
  rescue
    _exception -> {:error, :process_start_failed}
  catch
    _kind, _reason -> {:error, :process_start_failed}
  end

  defp port_guard(coordinator) do
    coordinator_monitor = Process.monitor(coordinator)

    receive do
      {:open_process_port, runner, reference, options} ->
        case open_port(options) do
          {:ok, port, helper_os_pid} ->
            runner_monitor = Process.monitor(runner)
            port_monitor = Port.monitor(port)
            send(runner, {:process_port_opened, self(), reference, port, helper_os_pid})

            guard_open_port(
              coordinator,
              coordinator_monitor,
              runner,
              runner_monitor,
              port,
              port_monitor,
              helper_os_pid,
              false
            )

          {:error, reason} ->
            send(runner, {:process_port_open_failed, self(), reference, reason})
        end

      {:stop_process_guard, requester, reference, _kill_grace_ms} ->
        send(requester, {:process_guard_stopped, self(), reference, :ok})

      {:DOWN, ^coordinator_monitor, :process, ^coordinator, _reason} ->
        :ok
    end
  end

  defp guard_open_port(
         coordinator,
         coordinator_monitor,
         runner,
         runner_monitor,
         port,
         port_monitor,
         helper_os_pid,
         terminal?
       ) do
    receive do
      {^port, {:exit_status, _status} = message} ->
        send(runner, {port, message})

        guard_open_port(
          coordinator,
          coordinator_monitor,
          runner,
          runner_monitor,
          port,
          port_monitor,
          helper_os_pid,
          true
        )

      {^port, message} ->
        send(runner, {port, message})

        guard_open_port(
          coordinator,
          coordinator_monitor,
          runner,
          runner_monitor,
          port,
          port_monitor,
          helper_os_pid,
          terminal?
        )

      {:process_port_bytes_handled, ^runner, reference, bytes} ->
        result = report_guarded_bytes(port, bytes)
        send(runner, {:process_port_bytes_reported, self(), reference, result})

        guard_open_port(
          coordinator,
          coordinator_monitor,
          runner,
          runner_monitor,
          port,
          port_monitor,
          helper_os_pid,
          terminal?
        )

      {:DOWN, ^port_monitor, :port, ^port, _reason} ->
        if terminal? do
          guard_terminal_port(
            coordinator,
            coordinator_monitor,
            runner,
            runner_monitor,
            helper_os_pid
          )
        else
          send(runner, {:process_port_failed, self()})
          result = wait_os_process_down(helper_os_pid, 1_500)
          send(coordinator, {:process_guard_cleanup, self(), result})
          if result == :error, do: exit(:process_cleanup_unconfirmed)
        end

      {:stop_process_guard, requester, reference, kill_grace_ms} ->
        result = close_guarded_port(port, helper_os_pid, kill_grace_ms)
        send(requester, {:process_guard_stopped, self(), reference, result})
        send(coordinator, {:process_guard_cleanup, self(), result})

      {:DOWN, ^runner_monitor, :process, ^runner, _reason} ->
        result = close_guarded_port(port, helper_os_pid, 500)
        send(coordinator, {:process_guard_cleanup, self(), result})
        if result == :error, do: exit(:process_cleanup_unconfirmed)

      {:DOWN, ^coordinator_monitor, :process, ^coordinator, _reason} ->
        result = close_guarded_port(port, helper_os_pid, 500)
        if result == :error, do: exit(:process_cleanup_unconfirmed)
    end
  end

  defp guard_terminal_port(
         coordinator,
         coordinator_monitor,
         runner,
         runner_monitor,
         helper_os_pid
       ) do
    receive do
      {:process_port_bytes_handled, ^runner, reference, _bytes} ->
        send(runner, {:process_port_bytes_reported, self(), reference, :ok})

        guard_terminal_port(
          coordinator,
          coordinator_monitor,
          runner,
          runner_monitor,
          helper_os_pid
        )

      {:DOWN, ^runner_monitor, :process, ^runner, _reason} ->
        result = wait_os_process_down(helper_os_pid, 1_500)
        send(coordinator, {:process_guard_cleanup, self(), result})
        if result == :error, do: exit(:process_cleanup_unconfirmed)

      {:DOWN, ^coordinator_monitor, :process, ^coordinator, _reason} ->
        if wait_os_process_down(helper_os_pid, 1_500) == :error,
          do: exit(:process_cleanup_unconfirmed)

      {:stop_process_guard, requester, reference, _kill_grace_ms} ->
        result = wait_os_process_down(helper_os_pid, 1_500)
        send(requester, {:process_guard_stopped, self(), reference, result})
        send(coordinator, {:process_guard_cleanup, self(), result})
    end
  end

  defp open_guarded_port(guard, options) do
    reference = make_ref()
    monitor = Process.monitor(guard)
    send(guard, {:open_process_port, self(), reference, options})

    receive do
      {:process_port_opened, ^guard, ^reference, port, helper_os_pid} ->
        {:ok, port, helper_os_pid, monitor}

      {:process_port_open_failed, ^guard, ^reference, reason} ->
        Process.demonitor(monitor, [:flush])
        {:error, reason}

      {:DOWN, ^monitor, :process, ^guard, _reason} ->
        {:error, :process_start_failed}
    end
  end

  defp open_port(options) do
    port =
      Port.open(
        {:spawn_executable, String.to_charlist(MuonTrap.Port.muontrap_path())},
        options
      )

    case Port.info(port, :os_pid) do
      {:os_pid, helper_os_pid} when is_integer(helper_os_pid) ->
        {:ok, port, helper_os_pid}

      _missing_pid ->
        if Port.info(port), do: Port.close(port)
        {:error, :process_start_failed}
    end
  rescue
    _exception -> {:error, :process_start_failed}
  catch
    _kind, _reason -> {:error, :process_start_failed}
  end

  defp report_bytes_handled(state, bytes) do
    reference = make_ref()
    monitor = Process.monitor(state.guard)

    send(
      state.guard,
      {:process_port_bytes_handled, self(), reference, bytes}
    )

    receive do
      {:process_port_bytes_reported, guard, ^reference, :ok} when guard == state.guard ->
        Process.demonitor(monitor, [:flush])
        :ok

      {:process_port_bytes_reported, guard, ^reference, :error} when guard == state.guard ->
        Process.demonitor(monitor, [:flush])
        exit(:process_port_report_failed)

      {:DOWN, ^monitor, :process, guard, _reason} when guard == state.guard ->
        exit(:process_port_guard_failed)
    end
  end

  defp report_guarded_bytes(port, bytes) do
    MuonTrap.Port.report_bytes_handled(port, bytes)
    :ok
  rescue
    _exception -> :error
  catch
    _kind, _reason -> :error
  end

  defp close_guarded_port(port, helper_os_pid, kill_grace_ms) do
    try do
      if Port.info(port), do: Port.close(port)
    rescue
      _exception -> :ok
    catch
      _kind, _reason -> :ok
    end

    wait_os_process_down(helper_os_pid, 2 * kill_grace_ms + 500)
  end

  defp stop_guard(guard, kill_grace_ms) do
    reference = make_ref()
    monitor = Process.monitor(guard)
    send(guard, {:stop_process_guard, self(), reference, kill_grace_ms})

    receive do
      {:process_guard_stopped, ^guard, ^reference, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:process_guard_cleanup, ^guard, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^guard, :normal} ->
        receive do
          {:process_guard_cleanup, ^guard, result} -> result
        after
          10 -> :ok
        end

      {:DOWN, ^monitor, :process, ^guard, _reason} ->
        :error
    after
      2 * kill_grace_ms + 1_000 ->
        Process.demonitor(monitor, [:flush])
        :error
    end
  end

  defp stop_port(state, kill_grace_ms) do
    case stop_guard(state.guard, kill_grace_ms) do
      :ok -> :ok
      :error -> wait_os_process_down(state.helper_os_pid, 2 * kill_grace_ms + 500)
    end
  end

  defp await_helper_cleanup(nil, kill_grace_ms) do
    case Process.get(:synapse_process_port_guard) do
      guard when is_pid(guard) -> stop_guard(guard, kill_grace_ms)
      _missing -> :error
    end
  end

  defp await_helper_cleanup(state, kill_grace_ms), do: stop_port(state, kill_grace_ms)

  defp wait_os_process_down(os_pid, remaining_ms) when remaining_ms <= 0 do
    if os_process_alive?(os_pid), do: :error, else: :ok
  end

  defp wait_os_process_down(os_pid, remaining_ms) do
    if os_process_alive?(os_pid) do
      Process.sleep(10)
      wait_os_process_down(os_pid, remaining_ms - 10)
    else
      :ok
    end
  end

  defp os_process_alive?(os_pid) do
    port =
      Port.open(
        {:spawn_executable, ~c"/bin/kill"},
        [
          :binary,
          :exit_status,
          :hide,
          :stderr_to_stdout,
          args: [~c"-0", Integer.to_charlist(os_pid)]
        ]
      )

    receive do
      {^port, {:exit_status, 0}} -> true
      {^port, {:exit_status, _status}} -> false
    after
      500 ->
        if Port.info(port), do: Port.close(port)
        true
    end
  end

  defp elapsed(started_at, spec, limits),
    do: min(max(now_ms() - started_at, 0), spec.timeout_ms + 2 * limits.kill_grace_ms)

  defp now_ms, do: System.monotonic_time(:millisecond)
end
