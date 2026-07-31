defmodule Synapse.ApplicationTest do
  use ExUnit.Case, async: true

  test "starts an intentionally empty named root supervisor" do
    supervisor = Process.whereis(Synapse.Supervisor)

    assert is_pid(supervisor)
    assert Process.alive?(supervisor)
    assert Supervisor.which_children(supervisor) == []
  end
end
