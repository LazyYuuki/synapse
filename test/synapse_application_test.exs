defmodule Synapse.ApplicationTest do
  use ExUnit.Case, async: false

  test "starts the exact named infrastructure children under one_for_one root policy" do
    root = Process.whereis(Synapse.Supervisor)

    assert is_pid(root)
    assert Process.alive?(root)

    assert {:ok, {flags, _children}} = Synapse.Supervisor.init([])
    assert flags.strategy == :one_for_one

    assert Enum.map(Synapse.Supervisor.child_specs(), & &1.id) == [
             Synapse.Workspace.Supervisor,
             Synapse.TaskSupervisor,
             Synapse.Runtime.Supervisor
           ]

    children =
      Map.new(Supervisor.which_children(root), fn {id, pid, type, modules} ->
        {id, {pid, type, modules}}
      end)

    assert children[Synapse.Workspace.Supervisor] ==
             {Process.whereis(Synapse.Workspace.Supervisor), :supervisor,
              [Synapse.Workspace.Supervisor]}

    assert children[Synapse.TaskSupervisor] ==
             {Process.whereis(Synapse.TaskSupervisor), :supervisor, [Task.Supervisor]}

    assert children[Synapse.Runtime.Supervisor] ==
             {Process.whereis(Synapse.Runtime.Supervisor), :supervisor,
              [Synapse.Runtime.Supervisor]}

    Enum.each(Synapse.Supervisor.child_specs(), fn spec ->
      assert spec.restart == :permanent
      assert spec.shutdown == :infinity
      assert spec.type == :supervisor
    end)
  end

  test "named DynamicSupervisors start empty with Runtime singleton capacity" do
    assert DynamicSupervisor.count_children(Synapse.Workspace.Supervisor) == %{
             active: 0,
             workers: 0,
             supervisors: 0,
             specs: 0
           }

    assert DynamicSupervisor.count_children(Synapse.Runtime.Supervisor) == %{
             active: 0,
             workers: 0,
             supervisors: 0,
             specs: 0
           }

    assert Task.Supervisor.children(Synapse.TaskSupervisor) == []
  end
end
