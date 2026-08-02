defmodule Synapse.Agent.LiveLoopTest do
  use ExUnit.Case, async: false

  alias Synapse.Agent.{Context, Runner}
  alias Synapse.Provider.Tokamak
  alias Synapse.Run.Event
  alias Synapse.Tool.CapabilitySet
  alias Synapse.Workspace
  alias Synapse.Workspace.{Access, Limits, OpenRequest}

  @moduletag :live_tokamak
  @moduletag timeout: 180_000

  @missing_environment Enum.reject(["TOKAMAK_API_KEY", "SYNAPSE_MODEL"], fn name ->
                         case System.get_env(name) do
                           value when is_binary(value) ->
                             String.valid?(value) and String.trim(value) != ""

                           _missing ->
                             false
                         end
                       end)

  @live_skip (cond do
                not Synapse.Workspace.Platform.supported?() ->
                  "requires a supported Real Workspace platform"

                @missing_environment != [] ->
                  "requires non-empty runtime environment: #{Enum.join(@missing_environment, ", ")}"

                true ->
                  false
              end)
  @moduletag skip: @live_skip

  test "public Runner completes one synthetic Tokamak coding task" do
    root = temporary_root()
    File.mkdir!(root)

    try do
      File.write!(Path.join(root, "fixture.txt"), "SYNAPSE_LIVE_AGENT_FIXTURE\n")
      handle = real_workspace(root)

      try do
        test_pid = self()

        {:ok, context} =
          Context.new(
            provider: Tokamak,
            workspace: handle,
            instructions: live_instructions(),
            event_sink: event_sink(test_pid),
            deadline: System.monotonic_time(:millisecond) + 150_000
          )

        assert {:ok, result} = Runner.run(run_request(root), context)

        assert String.trim(result.text) != ""
        assert result.tool_calls >= 1

        events = collect_tool_events([])
        assert Enum.any?(events, &match?({:started, _name}, &1))
        assert Enum.any?(events, &match?({:completed, "bash", :ok}, &1))

        assert File.read!(Path.join(root, "created.txt")) == "SYNAPSE_LIVE_AGENT_OK\n"

        assert {"SYNAPSE_LIVE_AGENT_VERIFY_OK", 0} =
                 System.cmd(
                   "/bin/bash",
                   [
                     "-lc",
                     "test \"$(cat created.txt)\" = SYNAPSE_LIVE_AGENT_OK && printf SYNAPSE_LIVE_AGENT_VERIFY_OK"
                   ],
                   cd: root,
                   stderr_to_stdout: true
                 )
      after
        Workspace.close(handle)
      end
    after
      File.rm_rf!(root)
    end
  end

  defp live_instructions do
    """
    Complete this synthetic task using the provided tools and then return a short final answer.
    1. Read fixture.txt.
    2. Create created.txt with exactly SYNAPSE_LIVE_AGENT_OK followed by one newline; use expected_revision missing.
    3. Run Bash to verify created.txt and print SYNAPSE_LIVE_AGENT_VERIFY_OK on success.
    Do not access any other path and do not skip the Bash verification.
    """
  end

  defp run_request(root) do
    {:ok, capabilities} =
      CapabilitySet.new(fs_read: true, fs_write: true, process_exec: true)

    {:ok, run} =
      Synapse.Run.Request.new(
        id: "run-live-agent-#{System.unique_integer([:positive, :monotonic])}",
        prompt: "Perform the synthetic coding acceptance task now.",
        cwd: root,
        model: System.fetch_env!("SYNAPSE_MODEL"),
        capabilities: capabilities,
        budget: Synapse.Budget.default()
      )

    run
  end

  defp real_workspace(root) do
    {:ok, request} =
      OpenRequest.new(
        root: root,
        owner: self(),
        limits: Limits.default(),
        access: %Access{read: true, write: true, exec: true}
      )

    {:ok, handle} = Workspace.open(request)
    handle
  end

  defp event_sink(test_pid) do
    fn
      %Event.ToolStarted{name: name} ->
        send(test_pid, {:live_tool_event, {:started, name}})
        :ok

      %Event.ToolCompleted{name: name, status: status} ->
        send(test_pid, {:live_tool_event, {:completed, name, status}})
        :ok

      _event ->
        :ok
    end
  end

  defp collect_tool_events(events) do
    receive do
      {:live_tool_event, event} -> collect_tool_events([event | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  defp temporary_root do
    Path.join(
      System.tmp_dir!(),
      "synapse-agent-live-#{Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)}"
    )
  end
end
