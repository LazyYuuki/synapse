defmodule Synapse.Agent.RealWorkspaceTest do
  use ExUnit.Case, async: false

  alias Synapse.Agent.{Context, OperationId, Runner}
  alias Synapse.Provider.{Fake, Response}
  alias Synapse.Provider.OutputItem.{FunctionCall, Message}
  alias Synapse.Run.Event
  alias Synapse.Tool.CapabilitySet
  alias Synapse.Workspace
  alias Synapse.Workspace.{Access, Limits, OpenRequest}

  @moduletag skip: not Synapse.Workspace.Platform.supported?()

  test "public Runner reads, writes, and verifies inside one temporary Real Workspace" do
    root = temporary_root()
    File.mkdir!(root)

    try do
      File.write!(Path.join(root, "fixture.txt"), "SYNAPSE_AGENT_FIXTURE\n")
      handle = real_workspace(root)

      try do
        run = run_request(root)
        provider_ids = provider_ids(run, 2)
        test_pid = self()

        calls = [
          call("item-read", "call-read", "read", %{
            "path" => "fixture.txt",
            "offset" => nil,
            "limit" => nil
          }),
          call("item-write", "call-write", "write", %{
            "path" => "created.txt",
            "content" => "agent acceptance\n",
            "expected_revision" => "missing"
          }),
          call("item-bash", "call-bash", "bash", %{
            "command" =>
              "test \"$(cat created.txt)\" = \"agent acceptance\" && printf SYNAPSE_AGENT_VERIFY_OK",
            "timeout_ms" => 5_000
          })
        ]

        script = [
          {:turn, [], {:ok, response!("response-real-tools", calls)}},
          {:turn, [], {:ok, text_response("response-real-final", "Temporary project verified.")}}
        ]

        {:ok, context} =
          Context.new(
            provider: Fake,
            workspace: handle,
            event_sink: event_sink(test_pid),
            deadline: System.monotonic_time(:millisecond) + 60_000
          )

        Fake.with_script(provider_ids, script, fn ->
          assert {:ok, result} = Runner.run(run, context)
          assert result.turns == 2
          assert result.tool_calls == 3
          assert String.trim(result.text) != ""
          assert Enum.all?(provider_ids, &(Fake.remaining_turns(&1) == {:ok, 0}))

          events = collect_events([])
          assert Enum.count(events, &match?(%Event.ToolCompleted{status: :ok}, &1)) == 3
          assert Enum.any?(events, &match?(%Event.RunCompleted{}, &1))
        end)

        assert File.read!(Path.join(root, "created.txt")) == "agent acceptance\n"

        assert {"SYNAPSE_AGENT_VERIFY_OK", 0} =
                 System.cmd(
                   "/bin/bash",
                   [
                     "-lc",
                     "test \"$(cat created.txt)\" = \"agent acceptance\" && printf SYNAPSE_AGENT_VERIFY_OK"
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

  defp run_request(root) do
    {:ok, capabilities} =
      CapabilitySet.new(fs_read: true, fs_write: true, process_exec: true)

    {:ok, run} =
      Synapse.Run.Request.new(
        id: "run-real-agent-#{System.unique_integer([:positive, :monotonic])}",
        prompt: "Inspect the fixture, create the requested file, and verify it.",
        cwd: root,
        model: "test-model",
        capabilities: capabilities,
        budget: Synapse.Budget.default()
      )

    run
  end

  defp provider_ids(run, turns),
    do: Enum.map(1..turns, fn turn -> elem(OperationId.provider(run.id, turn, 1), 1) end)

  defp response!(id, output_items) do
    {:ok, response} = Response.new(id: id, model: "test-model", output_items: output_items)
    response
  end

  defp text_response(id, text),
    do: response!(id, [%Message{id: "message-final", role: :assistant, content: text}])

  defp call(id, call_id, name, arguments),
    do: %FunctionCall{id: id, call_id: call_id, name: name, arguments: arguments}

  defp event_sink(test_pid) do
    fn event ->
      send(test_pid, {:run_event, event})
      :ok
    end
  end

  defp collect_events(events) do
    receive do
      {:run_event, event} -> collect_events([event | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  defp temporary_root do
    Path.join(
      System.tmp_dir!(),
      "synapse-agent-real-#{Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)}"
    )
  end
end
