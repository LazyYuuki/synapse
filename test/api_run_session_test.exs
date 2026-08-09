defmodule Synapse.API.RunSessionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Synapse.Agent.{Error, Result}
  alias Synapse.API
  alias Synapse.API.{Config, RunManager, RunSession}
  alias Synapse.API.RunSession.{RuntimeBoundary, StartArguments, State}
  alias Synapse.Budget
  alias Synapse.Provider
  alias Synapse.Run.Event
  alias Synapse.Runtime.Error, as: RuntimeError
  alias Synapse.Runtime.Run
  alias Synapse.Runtime.RunServer.Message
  alias Synapse.Workspace

  test "the admitted RunSession PID starts Runtime and performs every await poll" do
    {:ok, server_budget} = Budget.new(max_turns: 10)
    {:ok, command_budget} = Budget.new(max_turns: 5)

    {:ok, config} =
      Config.new(
        enabled: true,
        launch_cwd: "/synthetic/api-run-session-launch",
        default_model: "model-a",
        budget: server_budget
      )

    harness = start_harness(config)

    conversation = [
      %{"role" => "user", "content" => "Earlier question"},
      %{"role" => "assistant", "content" => "Earlier answer"}
    ]

    command = start_command(config, budget: command_budget, conversation: conversation)

    assert {:ok, run_id} = RunManager.start_run(harness.manager, command)

    assert_receive {:runtime_start, session, start_ref, request, sink, options}
    assert request.id == run_id
    assert request.prompt == command.prompt
    assert request.conversation == command.conversation
    assert request.cwd == command.cwd
    assert request.model == command.model
    assert request.budget == command_budget
    assert request.capabilities == config.capabilities
    assert options == config.runtime_options
    assert run(harness.manager, run_id).session_pid == session

    runtime_run = runtime_run(run_id, session)
    send(session, {:runtime_start_reply, start_ref, {:ok, runtime_run}})

    assert_receive {:runtime_await, ^session, first_ref, ^runtime_run, 1_000}
    status_task = Task.async(fn -> :sys.get_status(session) end)
    send(session, :unrelated_mailbox_traffic)
    send(session, {:runtime_await_reply, first_ref, {:error, :await_timeout}})
    status = Task.await(status_task, 5_000)
    assert inspect(status) =~ "redacted"

    assert_receive {:runtime_await, ^session, second_ref, ^runtime_run, 1_000}
    send(session, {:runtime_await_reply, second_ref, {:error, :await_timeout}})
    assert_receive {:runtime_await, ^session, third_ref, ^runtime_run, 1_000}

    result = agent_result(run_id, "finished")
    assert :ok = sink.(event(:run_completed, run_id: run_id, result: result))
    monitor = Process.monitor(session)
    send(session, {:runtime_await_reply, third_ref, {:ok, result}})

    assert_receive {:DOWN, ^monitor, :process, ^session, :normal}
    record = run(harness.manager, run_id)
    assert record.status == :completed
    assert record.terminal.result.text == "finished"
    refute_received {:runtime_cancel, _caller, ^runtime_run}
    assert DynamicSupervisor.count_children(harness.supervisor).active == 0
  end

  test "a Runtime terminal queued between polls is preserved for owner-only await" do
    config = default_config()
    harness = start_harness(config)
    {run_id, session, runtime_run, sink, first_await} = start_until_await(harness, config)
    result = agent_result(run_id, "queued terminal")
    assert :ok = sink.(event(:run_completed, run_id: run_id, result: result))

    send(session, %Message{
      kind: :terminal,
      run_ref: runtime_run.run_ref,
      worker: nil,
      payload: {:ok, result}
    })

    send(session, {:runtime_await_reply, first_await, {:error, :await_timeout}})
    assert_receive {:runtime_await, ^session, second_await, ^runtime_run, 1_000}
    monitor = Process.monitor(session)
    send(session, {:runtime_await_reply, second_await, :consume_runtime_terminal})
    assert_receive {:DOWN, ^monitor, :process, ^session, :normal}
    assert run(harness.manager, run_id).status == :completed
  end

  test "blocked Runtime startup does not block Manager and early cancellation applies on registration" do
    config = default_config()
    harness = start_harness(config)
    assert {:ok, run_id} = RunManager.start_run(harness.manager, start_command(config))
    assert_receive {:runtime_start, session, start_ref, _request, sink, _options}

    assert {:ok, :cancel_requested} = RunManager.cancel(harness.manager, run_id)
    assert {:error, :run_busy} = RunManager.start_run(harness.manager, start_command(config))
    assert run(harness.manager, run_id).runtime_run == nil
    refute_received {:runtime_cancel, _caller, _run}

    runtime_run = runtime_run(run_id, session)
    send(session, {:runtime_start_reply, start_ref, {:ok, runtime_run}})
    assert_receive {:runtime_cancel, manager, ^runtime_run}
    assert manager == harness.manager
    assert_receive {:runtime_await, ^session, await_ref, ^runtime_run, 1_000}

    error = agent_error(run_id, :cancelled, :run_cancelled)
    assert :ok = sink.(event(:run_interrupted, run_id: run_id, error: error))
    monitor = Process.monitor(session)
    send(session, {:runtime_await_reply, await_ref, {:error, error}})
    assert_receive {:DOWN, ^monitor, :process, ^session, :normal}
    assert run(harness.manager, run_id).status == :interrupted
  end

  test "real synchronous Workspace opening does not block Manager admission or cancellation" do
    test_pid = self()

    opener = fn open_request ->
      {:ok, handle} =
        Workspace.Fake.open([],
          owner: open_request.owner,
          limits: open_request.limits,
          access: open_request.access
        )

      send(test_pid, {:real_workspace_open_blocked, self(), handle.state})

      receive do
        :release_real_workspace -> {:ok, handle}
      after
        10_000 -> exit(:real_workspace_release_timeout)
      end
    end

    {:ok, options} =
      Synapse.Runtime.Options.new(
        provider: Synapse.Provider.Fake,
        workspace_opener: opener
      )

    {:ok, config} =
      Config.new(
        enabled: true,
        launch_cwd: "/synthetic/api-run-session-launch",
        default_model: "model-a",
        runtime_options: options
      )

    harness = start_harness(config, runtime: RuntimeBoundary.default(), id: 42)
    assert {:ok, run_id} = RunManager.start_run(harness.manager, start_command(config))
    session = run(harness.manager, run_id).session_pid
    monitor = Process.monitor(session)
    assert_receive {:real_workspace_open_blocked, runtime_task, backend}, 5_000
    on_exit(fn -> send(runtime_task, :release_real_workspace) end)

    assert {:ok, :cancel_requested} = RunManager.cancel(harness.manager, run_id)
    assert {:error, :run_busy} = RunManager.start_run(harness.manager, start_command(config))
    assert run(harness.manager, run_id).runtime_run == nil

    backend_monitor = Process.monitor(backend)
    send(runtime_task, :release_real_workspace)
    assert_receive {:DOWN, ^monitor, :process, ^session, :normal}, 10_000
    assert_receive {:DOWN, ^backend_monitor, :process, ^backend, _reason}, 10_000
    assert run(harness.manager, run_id).status == :interrupted
    assert run(harness.manager, run_id).terminal.error.reason == :run_cancelled
  end

  test "cancellation immediately after registration is delegated only by Manager" do
    config = default_config()
    harness = start_harness(config)
    {run_id, session, runtime_run, sink, await_ref} = start_until_await(harness, config)

    assert {:ok, :cancel_requested} = RunManager.cancel(harness.manager, run_id)
    assert_receive {:runtime_cancel, caller, ^runtime_run}
    assert caller == harness.manager

    error = agent_error(run_id, :cancelled, :run_cancelled)
    assert :ok = sink.(event(:run_interrupted, run_id: run_id, error: error))
    send(session, {:runtime_await_reply, await_ref, {:error, error}})
    assert_session_down(session, :normal)
    assert run(harness.manager, run_id).status == :interrupted
  end

  test "Agent Error, Runtime Error, and startup Runtime Error settle through typed Manager paths" do
    config = default_config()

    failure = start_harness(config, id: 1)

    {failed_id, failed_session, _run, failed_sink, failed_await} =
      start_until_await(failure, config)

    agent_error = agent_error(failed_id, :provider, :provider_failed)
    assert :ok = failed_sink.(event(:run_failed, run_id: failed_id, error: agent_error))
    send(failed_session, {:runtime_await_reply, failed_await, {:error, agent_error}})
    assert_session_down(failed_session, :normal)
    assert run(failure.manager, failed_id).status == :failed

    lost = start_harness(config, id: 2)
    {lost_id, lost_session, _run, _sink, lost_await} = start_until_await(lost, config)
    {:ok, runtime_lost} = RuntimeError.new(reason: :runtime_lost, run_id: lost_id)
    send(lost_session, {:runtime_await_reply, lost_await, {:error, runtime_lost}})
    assert_session_down(lost_session, :normal)
    assert run(lost.manager, lost_id).status == :interrupted
    assert run(lost.manager, lost_id).terminal.error.reason == :runtime_lost

    startup = start_harness(config, id: 3)
    assert {:ok, startup_id} = RunManager.start_run(startup.manager, start_command(config))
    assert_receive {:runtime_start, startup_session, start_ref, _request, _sink, _options}
    {:ok, open_error} = RuntimeError.new(reason: :workspace_open_failed, run_id: startup_id)
    send(startup_session, {:runtime_start_reply, start_ref, {:error, open_error}})
    assert_session_down(startup_session, :normal)
    assert run(startup.manager, startup_id).status == :failed
    refute_received {:runtime_await, ^startup_session, _ref, _run, _timeout}
  end

  test "malformed Runtime startup and await returns are sanitized without false settlement" do
    config = default_config()
    startup = start_harness(config, id: 4)
    assert {:ok, run_id} = RunManager.start_run(startup.manager, start_command(config))
    assert_receive {:runtime_start, session, start_ref, _request, _sink, _options}
    send(session, {:runtime_start_reply, start_ref, {:ok, %{forged: :run}}})
    assert_session_down(session, :normal)
    assert run(startup.manager, run_id).terminal.error.reason == :runtime_unavailable

    awaiting = start_harness(config, id: 5)

    {await_id, await_session, runtime_run, _sink, await_ref} =
      start_until_await(awaiting, config)

    send(await_session, {:runtime_await_reply, await_ref, {:error, :not_owner}})
    assert_receive {:runtime_cancel, ^await_session, ^runtime_run}
    assert_session_down(await_session, :normal)
    assert run(awaiting.manager, await_id).status == :owner_lost
    assert run(awaiting.manager, await_id).terminal == nil
  end

  test "Runtime callback raise, throw, and exit paths are sanitized without secret logs" do
    config = default_config()
    secret = "RUN_SESSION_CALLBACK_FAILURE_SECRET"

    log =
      capture_log(fn ->
        for {kind, id} <- Enum.with_index([:raise, :throw, :exit], 20) do
          harness = start_harness(config, id: id)
          assert {:ok, run_id} = RunManager.start_run(harness.manager, start_command(config))
          assert_receive {:runtime_start, session, start_ref, _request, _sink, _options}
          send(session, {:runtime_start_reply, start_ref, {kind, secret}})
          assert_session_down(session, :normal)
          assert run(harness.manager, run_id).terminal.error.reason == :runtime_unavailable
        end

        for {kind, id} <- Enum.with_index([:raise, :throw, :exit], 30) do
          harness = start_harness(config, id: id)
          {run_id, session, runtime_run, _sink, await_ref} = start_until_await(harness, config)
          send(session, {:runtime_await_reply, await_ref, {kind, secret}})
          assert_receive {:runtime_cancel, ^session, ^runtime_run}
          assert_session_down(session, :normal)
          assert run(harness.manager, run_id).status == :owner_lost
          assert run(harness.manager, run_id).terminal == nil
        end

        harness = start_harness(config, id: 40, cancel_behavior: {:raise, secret})
        {run_id, session, runtime_run, _sink, await_ref} = start_until_await(harness, config)
        assert {:ok, :cancel_requested} = RunManager.cancel(harness.manager, run_id)
        assert_receive {:runtime_cancel, manager, ^runtime_run}
        assert manager == harness.manager
        send(session, {:runtime_await_reply, await_ref, {:error, :not_owner}})
        assert_receive {:runtime_cancel, ^session, ^runtime_run}
        assert_session_down(session, :normal)
        assert Process.alive?(harness.manager)
        assert run(harness.manager, run_id).status == :owner_lost
      end)

    refute log =~ secret
  end

  test "Manager DOWN cancels from RunSession after the bounded await returns" do
    config = default_config()
    harness = start_harness(config)
    {_run_id, session, runtime_run, _sink, await_ref} = start_until_await(harness, config)
    Process.unlink(harness.manager)
    Process.exit(harness.manager, :kill)
    monitor = Process.monitor(session)
    send(session, {:runtime_await_reply, await_ref, {:error, :await_timeout}})
    assert_receive {:runtime_cancel, ^session, ^runtime_run}
    assert_receive {:DOWN, ^monitor, :process, ^session, :normal}
  end

  test "graceful child shutdown runs terminate cancellation and Manager handles session DOWN" do
    config = default_config()
    harness = start_harness(config)
    {run_id, session, runtime_run, _sink, await_ref} = start_until_await(harness, config)
    monitor = Process.monitor(session)

    test_pid = self()

    {terminator, terminator_monitor} =
      spawn_monitor(fn ->
        receive do
          :stop -> GenServer.stop(session, :shutdown, 5_000)
        after
          5_000 -> exit(:graceful_stop_timeout)
        end

        send(test_pid, :graceful_stop_complete)
      end)

    :erlang.trace(terminator, true, [:send])
    send(terminator, :stop)

    assert_receive {:trace, ^terminator, :send, {:system, _from, {:terminate, :shutdown}},
                    ^session}

    send(session, {:runtime_await_reply, await_ref, {:error, :await_timeout}})

    cancellations =
      for _ordinal <- 1..2 do
        assert_receive {:runtime_cancel, caller, ^runtime_run}, 5_000
        caller
      end

    assert session in cancellations
    assert harness.manager in cancellations
    assert_receive :graceful_stop_complete
    assert_receive {:DOWN, ^terminator_monitor, :process, ^terminator, :normal}
    assert_receive {:DOWN, ^monitor, :process, ^session, :shutdown}
    assert run(harness.manager, run_id).status == :owner_lost
  end

  test "an uncatchable session crash is never restarted and Manager performs cleanup" do
    config = default_config()
    harness = start_harness(config)
    {run_id, session, runtime_run, _sink, _await_ref} = start_until_await(harness, config)
    monitor = Process.monitor(session)
    Process.exit(session, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^session, :killed}
    assert_receive {:runtime_cancel, caller, ^runtime_run}
    assert caller == harness.manager
    refute_received {:runtime_cancel, ^session, ^runtime_run}
    assert_receive {:synapse_run_changed, ^run_id}
    assert run(harness.manager, run_id).status == :owner_lost
    assert DynamicSupervisor.count_children(harness.supervisor).active == 0
    refute_received {:runtime_start, _new_session, _ref, _request, _sink, _options}
  end

  test "startup arguments, state, status, and logs redact prompt, path, callbacks, and handle" do
    secret = "SYNTHETIC_RUN_SESSION_PHASE4_SECRET"
    callback_secret = "SYNTHETIC_RUN_SESSION_CALLBACK_SECRET"
    path = "/tmp/#{secret}"

    {:ok, runtime_options} =
      Synapse.Runtime.Options.new(
        provider: Synapse.Provider.Fake,
        instructions: secret,
        retry_delay: fn _ordinal -> byte_size(callback_secret) - byte_size(callback_secret) end,
        workspace_opener: fn _request -> {:error, callback_secret} end
      )

    {:ok, config} =
      Config.new(
        enabled: true,
        launch_cwd: "/synthetic/api-run-session-launch",
        default_model: "model-a",
        runtime_options: runtime_options
      )

    harness = start_harness(config)
    command = start_command(config, prompt: secret, cwd: path)

    arguments = %StartArguments{
      manager: harness.manager,
      run_id: run_id(9),
      command: command,
      config: config,
      runtime: harness.runtime
    }

    state = %State{
      phase: :starting,
      manager: harness.manager,
      manager_monitor: make_ref(),
      run_id: run_id(9),
      command: command,
      config: config,
      runtime_run: nil,
      runtime: harness.runtime
    }

    for value <- [arguments, state, harness.runtime] do
      refute inspect(value) =~ secret
      refute inspect(value) =~ callback_secret
      refute inspect(value) =~ path
      refute inspect(value) =~ "#Function<"
    end

    authority =
      spawn(fn ->
        receive do
          :stop -> :ok
        after
          10_000 -> exit(:authority_stop_timeout)
        end
      end)

    authority_sentinel = inspect(authority)
    on_exit(fn -> send(authority, :stop) end)

    log =
      capture_log(fn ->
        assert {:ok, run_id} = RunManager.start_run(harness.manager, command)
        assert_receive {:runtime_start, session, start_ref, _request, _sink, _options}
        runtime_run = runtime_run(run_id, session, authority)
        send(session, {:runtime_start_reply, start_ref, {:ok, runtime_run}})
        assert_receive {:runtime_await, ^session, await_ref, ^runtime_run, 1_000}
        status_task = Task.async(fn -> :sys.get_status(session) end)
        send(session, {:runtime_await_reply, await_ref, {:error, :await_timeout}})
        status = Task.await(status_task, 5_000)
        refute inspect(status) =~ secret
        refute inspect(status) =~ callback_secret
        refute inspect(status) =~ path
        refute inspect(status) =~ authority_sentinel
        refute inspect(status) =~ "#Function<"
        Process.exit(session, :kill)
        assert_session_down(session, :killed)
      end)

    refute log =~ secret
    refute log =~ callback_secret
    refute log =~ path
    refute log =~ authority_sentinel
  end

  defp start_harness(config, options \\ []) do
    test_pid = self()

    runtime =
      Keyword.get(
        options,
        :runtime,
        runtime_boundary(test_pid, Keyword.get(options, :cancel_behavior, :ok))
      )

    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one, max_children: 1)
    starter = RunSession.session_starter(supervisor, config, runtime)

    {:ok, manager} =
      RunManager.start_link(
        name: nil,
        config: config,
        session_starter: starter,
        cancel_run: runtime.cancel,
        id_generator: fn -> run_id(Keyword.get(options, :id, 0)) end
      )

    on_exit(fn -> stop_harness(manager, supervisor) end)
    %{manager: manager, supervisor: supervisor, runtime: runtime}
  end

  defp runtime_boundary(test_pid, cancel_behavior) do
    {:ok, runtime} =
      RuntimeBoundary.new(
        start_run: fn request, sink, options ->
          reference = make_ref()
          send(test_pid, {:runtime_start, self(), reference, request, sink, options})

          receive do
            {:runtime_start_reply, ^reference, {:raise, reason}} -> raise reason
            {:runtime_start_reply, ^reference, {:throw, reason}} -> throw(reason)
            {:runtime_start_reply, ^reference, {:exit, reason}} -> exit(reason)
            {:runtime_start_reply, ^reference, result} -> result
          after
            5_000 -> {:error, :test_timeout}
          end
        end,
        await: fn run, timeout ->
          reference = make_ref()
          send(test_pid, {:runtime_await, self(), reference, run, timeout})

          receive do
            {:runtime_await_reply, ^reference, :consume_runtime_terminal} ->
              receive do
                %Message{kind: :terminal, run_ref: run_ref, worker: nil, payload: payload}
                when run_ref == run.run_ref ->
                  payload
              after
                5_000 -> {:error, :test_timeout}
              end

            {:runtime_await_reply, ^reference, {:raise, reason}} ->
              raise reason

            {:runtime_await_reply, ^reference, {:throw, reason}} ->
              throw(reason)

            {:runtime_await_reply, ^reference, {:exit, reason}} ->
              exit(reason)

            {:runtime_await_reply, ^reference, result} ->
              result
          after
            5_000 -> {:error, :test_timeout}
          end
        end,
        cancel: fn run ->
          send(test_pid, {:runtime_cancel, self(), run})

          case cancel_behavior do
            :ok -> :ok
            {:raise, reason} -> raise reason
            {:throw, reason} -> throw(reason)
            {:exit, reason} -> exit(reason)
          end
        end
      )

    runtime
  end

  defp start_until_await(harness, config) do
    assert {:ok, run_id} = RunManager.start_run(harness.manager, start_command(config))
    assert_receive {:runtime_start, session, start_ref, _request, sink, _options}
    runtime_run = runtime_run(run_id, session)
    send(session, {:runtime_start_reply, start_ref, {:ok, runtime_run}})
    assert_receive {:runtime_await, ^session, await_ref, ^runtime_run, 1_000}
    {run_id, session, runtime_run, sink, await_ref}
  end

  defp stop_harness(manager, supervisor) do
    if Process.alive?(supervisor) do
      DynamicSupervisor.which_children(supervisor)
      |> Enum.each(fn {_id, pid, _type, _modules} -> Process.exit(pid, :kill) end)

      Supervisor.stop(supervisor)
    end

    if Process.alive?(manager), do: GenServer.stop(manager)
  catch
    :exit, _reason -> :ok
  end

  defp default_config do
    {:ok, config} =
      Config.new(
        enabled: true,
        launch_cwd: "/synthetic/api-run-session-launch",
        default_model: "model-a"
      )

    config
  end

  defp start_command(config, overrides \\ []) do
    attrs = %{
      prompt: Keyword.get(overrides, :prompt, "Inspect"),
      conversation: Keyword.get(overrides, :conversation, []),
      cwd: Keyword.get(overrides, :cwd, "/tmp/project"),
      model: "model-a",
      budget: Keyword.get(overrides, :budget, config.budget)
    }

    {:ok, command} = API.Command.Start.new(attrs, config)
    command
  end

  defp event(kind, attrs) do
    {:ok, event} = Event.new(kind, attrs)
    event
  end

  defp agent_result(run_id, text) do
    {:ok, response} =
      Provider.Response.new(id: "response-1", model: "model-a", output_items: [], usage: %{})

    {:ok, result} =
      Result.new(
        run_id: run_id,
        text: text,
        final_response: response,
        turns: 1,
        tool_calls: 0,
        provider_retries: 0,
        output_bytes: byte_size(text)
      )

    result
  end

  defp agent_error(run_id, kind, reason) do
    {:ok, error} =
      Error.new(
        kind: kind,
        reason: reason,
        message: "Sanitized failure",
        run_id: run_id,
        turn: 1,
        operation_id: nil,
        details: %{}
      )

    error
  end

  defp runtime_run(run_id, owner, authority \\ nil) do
    authority = authority || owner

    %Run{
      id: run_id,
      owner: owner,
      server: authority,
      task: authority,
      run_ref: make_ref(),
      cancel_ref: make_ref(),
      cancellation: :atomics.new(1, signed: false),
      await_state: :atomics.new(1, signed: false)
    }
  end

  defp assert_session_down(session, reason) do
    monitor = Process.monitor(session)

    if Process.alive?(session) do
      assert_receive {:DOWN, ^monitor, :process, ^session, ^reason}, 5_000
    else
      assert_receive {:DOWN, ^monitor, :process, ^session, :noproc}
    end
  end

  defp run(manager, run_id), do: :sys.get_state(manager).runs[run_id]
  defp run_id(value), do: "run_" <> Base.url_encode64(<<value::128>>, padding: false)
end
