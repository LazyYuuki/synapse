defmodule Synapse.WorkspacePhase0Test do
  use ExUnit.Case, async: true

  test "same-directory rename atomically replaces a complete staged file" do
    in_temporary_directory(fn root ->
      target = Path.join(root, "target.txt")
      stage = Path.join(root, ".target.stage")

      File.write!(target, "old")
      File.chmod!(target, 0o640)
      mode = File.stat!(target).mode

      {:ok, io} = File.open(stage, [:write, :binary, :exclusive])
      :ok = IO.binwrite(io, "complete new content")
      :ok = :file.sync(io)
      :ok = File.close(io)
      :ok = File.chmod(stage, mode)
      :ok = File.rename(stage, target)

      assert File.read!(target) == "complete new content"
      assert File.stat!(target).mode == mode
      refute File.exists?(stage)
    end)
  end

  test "concurrent APFS observers see old or complete new content around rename" do
    in_temporary_directory(fn root ->
      target = Path.join(root, "observed.txt")
      stage = Path.join(root, ".observed.stage")
      old_content = String.duplicate("old-", 16_384)
      new_content = String.duplicate("new-", 16_384)
      test_pid = self()

      File.write!(target, old_content)
      File.write!(stage, new_content)

      observer =
        Task.async(fn ->
          assert File.read!(target) == old_content
          send(test_pid, :observer_observed_old)
          observe_atomic_states(target, old_content, new_content, test_pid, false)
        end)

      assert_receive :observer_observed_old
      :ok = File.rename(stage, target)
      assert_receive :observer_observed_new
      send(observer.pid, :stop_observer)

      assert :ok = Task.await(observer)
      assert File.read!(target) == new_content
    end)
  end

  test "hard-link commit creates a complete file without overwriting an existing name" do
    in_temporary_directory(fn root ->
      stage = Path.join(root, ".created.stage")
      target = Path.join(root, "created.txt")

      File.write!(stage, "complete before publication")
      stage_mode = File.stat!(stage).mode
      assert :ok = File.ln(stage, target)
      assert File.stat!(stage).links == 2
      assert File.stat!(target).links == 2
      assert :ok = File.rm(stage)
      assert File.stat!(target).links == 1
      assert File.stat!(target).mode == stage_mode
      assert File.read!(target) == "complete before publication"

      second_stage = Path.join(root, ".second.stage")
      File.write!(second_stage, "must not replace")
      assert {:error, :eexist} = File.ln(second_stage, target)
      assert File.read!(target) == "complete before publication"
    end)
  end

  test "private process HOME and TMPDIR can be owner-only and removed on close" do
    in_temporary_directory(fn root ->
      runtime = Path.join(root, ".synapse-runtime")
      home = Path.join(runtime, "home")
      tmp = Path.join(runtime, "tmp")

      File.mkdir_p!(home)
      File.mkdir_p!(tmp)
      File.chmod!(runtime, 0o700)
      File.chmod!(home, 0o700)
      File.chmod!(tmp, 0o700)

      assert Bitwise.band(File.stat!(runtime).mode, 0o777) == 0o700
      assert Bitwise.band(File.stat!(home).mode, 0o777) == 0o700
      assert Bitwise.band(File.stat!(tmp).mode, 0o777) == 0o700

      File.rm_rf!(runtime)
      refute File.exists?(runtime)
    end)
  end

  test "lstat distinguishes a descendant symlink before file access" do
    in_temporary_directory(fn root ->
      outside = Path.join(Path.dirname(root), "outside-#{System.unique_integer([:positive])}")
      link = Path.join(root, "escape")
      on_exit(fn -> File.rm(outside) end)

      File.write!(outside, "outside")
      File.ln_s!(outside, link)

      assert %File.Stat{type: :symlink} = File.lstat!(link)
      assert File.read_link!(link) == outside

      root_stat = File.stat!(root)
      file_stat = File.stat!(outside)
      assert root_stat.major_device == file_stat.major_device
      assert root_stat.minor_device == file_stat.minor_device

      File.rm!(outside)
      assert %File.Stat{type: :symlink} = File.lstat!(link)
      assert {:error, :enoent} = File.stat(link)
    end)
  end

  test "renaming the root invalidates its original canonical pathname" do
    in_temporary_directory(fn root ->
      renamed = root <> "-renamed"
      on_exit(fn -> File.rm_rf(renamed) end)
      File.write!(Path.join(root, "file.txt"), "content")

      assert :ok = File.rename(root, renamed)
      refute File.exists?(root)
      assert File.read!(Path.join(renamed, "file.txt")) == "content"
    end)
  end

  test "Port environment options can remove every inherited variable" do
    executable = System.find_executable("env") || flunk("env executable is required")

    cleared_environment =
      System.get_env()
      |> Map.keys()
      |> Enum.map(&{String.to_charlist(&1), false})

    allowed_name = ~c"SYNAPSE_WORKSPACE_ALLOWED"
    allowed_value = ~c"phase-zero"

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(executable)},
        [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          args: [],
          env: cleared_environment ++ [{allowed_name, allowed_value}]
        ]
      )

    assert {0, output} = collect_port(port)
    assert output == "SYNAPSE_WORKSPACE_ALLOWED=phase-zero\n"
  end

  test "closing a raw Port does not terminate its direct child on the verified platform" do
    executable = System.find_executable("sleep") || flunk("sleep executable is required")

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(executable)},
        [:binary, :exit_status, args: [~c"30"]]
      )

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    on_exit(fn -> terminate_os_process(os_pid) end)
    monitor = Port.monitor(port)
    assert os_process_alive?(os_pid)

    true = Port.close(port)

    assert_receive {:DOWN, ^monitor, :port, ^port, _reason}, 1_000
    assert os_process_alive?(os_pid)
  end

  test "raw Port owner death does not terminate its direct child on the verified platform" do
    test_pid = self()
    executable = System.find_executable("sleep") || flunk("sleep executable is required")

    owner =
      spawn(fn ->
        port =
          Port.open(
            {:spawn_executable, String.to_charlist(executable)},
            [:binary, :exit_status, args: [~c"30"]]
          )

        {:os_pid, os_pid} = Port.info(port, :os_pid)
        send(test_pid, {:owned_process, os_pid})
        Process.sleep(:infinity)
      end)

    owner_monitor = Process.monitor(owner)
    assert_receive {:owned_process, os_pid}, 1_000
    on_exit(fn -> terminate_os_process(os_pid) end)
    assert os_process_alive?(os_pid)

    Process.exit(owner, :kill)

    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :killed}, 1_000
    assert os_process_alive?(os_pid)
  end

  test "MuonTrap owner death terminates its direct child" do
    in_temporary_directory(fn root ->
      pid_file = Path.join(root, "muontrap-owner.pid")
      owner = spawn_muontrap_sleep(pid_file)
      owner_monitor = Process.monitor(owner)
      os_pid = await_pid_file(pid_file)
      on_exit(fn -> terminate_os_process(os_pid) end)
      assert os_process_alive?(os_pid)

      Process.exit(owner, :kill)

      assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :killed}, 1_000
      assert eventually(fn -> not os_process_alive?(os_pid) end)
    end)
  end

  test "a matching cancellation message can stop the MuonTrap command owner and child" do
    in_temporary_directory(fn root ->
      test_pid = self()
      pid_file = Path.join(root, "muontrap-cancel.pid")
      cancel_ref = make_ref()

      coordinator =
        spawn(fn ->
          worker = spawn_muontrap_sleep(pid_file)
          worker_monitor = Process.monitor(worker)

          receive do
            {:cancel, ^cancel_ref} ->
              Process.exit(worker, :kill)
              assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 1_000
              send(test_pid, :cancelled_worker_down)
          end
        end)

      os_pid = await_pid_file(pid_file)
      on_exit(fn -> terminate_os_process(os_pid) end)
      assert os_process_alive?(os_pid)

      send(coordinator, {:cancel, cancel_ref})

      assert_receive :cancelled_worker_down, 1_000
      assert eventually(fn -> not os_process_alive?(os_pid) end)
    end)
  end

  test "MuonTrap timeout terminates its direct child" do
    in_temporary_directory(fn root ->
      pid_file = Path.join(root, "muontrap-timeout.pid")
      test_pid = self()

      owner =
        spawn(fn ->
          result =
            MuonTrap.cmd(
              "/bin/bash",
              [
                "-c",
                "printf '%s' \"$$\" > \"$1\"; trap '' TERM; while :; do :; done",
                "bash",
                pid_file
              ],
              timeout: 100,
              delay_to_sigkill: 1_000
            )

          send(test_pid, {:muontrap_timeout_result, result})
        end)

      os_pid = await_pid_file(pid_file)
      on_exit(fn -> terminate_os_process(os_pid) end)

      assert_receive {:muontrap_timeout_result, {_output, :timeout}}, 2_000
      refute Process.alive?(owner)
      assert eventually(fn -> not os_process_alive?(os_pid) end)
    end)
  end

  test "MuonTrap streams command output through a Collectable" do
    assert {chunks, 0} =
             MuonTrap.cmd("/bin/bash", ["-c", "printf first; printf second; sleep 0.05"],
               into: []
             )

    assert IO.iodata_to_binary(chunks) == "firstsecond"
    assert Enum.all?(chunks, &is_binary/1)
  end

  defp collect_port(port, output \\ []) do
    receive do
      {^port, {:data, data}} ->
        collect_port(port, [data | output])

      {^port, {:exit_status, status}} ->
        {status, output |> Enum.reverse() |> IO.iodata_to_binary()}
    after
      5_000 -> flunk("Port did not terminate within the phase-zero test deadline")
    end
  end

  defp observe_atomic_states(path, old_content, new_content, owner, observed_new?) do
    receive do
      :stop_observer ->
        :ok
    after
      0 ->
        case File.read(path) do
          {:ok, ^old_content} ->
            observe_atomic_states(path, old_content, new_content, owner, observed_new?)

          {:ok, ^new_content} ->
            unless observed_new?, do: send(owner, :observer_observed_new)
            observe_atomic_states(path, old_content, new_content, owner, true)

          unexpected ->
            {:unexpected_state, unexpected}
        end
    end
  end

  defp os_process_alive?(os_pid) do
    case System.cmd("/bin/kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  end

  defp terminate_os_process(os_pid) do
    if os_process_alive?(os_pid) do
      System.cmd("/bin/kill", ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true)

      unless eventually(fn -> not os_process_alive?(os_pid) end) do
        System.cmd("/bin/kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
      end
    end

    :ok
  end

  defp spawn_muontrap_sleep(pid_file) do
    spawn(fn ->
      MuonTrap.cmd(
        "/bin/bash",
        ["-c", "printf '%s' \"$$\" > \"$1\"; exec /bin/sleep 30", "bash", pid_file]
      )
    end)
  end

  defp await_pid_file(pid_file, attempts \\ 100)
  defp await_pid_file(_pid_file, 0), do: flunk("MuonTrap child did not publish its PID")

  defp await_pid_file(pid_file, attempts) do
    case File.read(pid_file) do
      {:ok, value} ->
        String.to_integer(value)

      {:error, :enoent} ->
        Process.sleep(20)
        await_pid_file(pid_file, attempts - 1)
    end
  end

  defp eventually(predicate, attempts \\ 50)
  defp eventually(predicate, 0), do: predicate.()

  defp eventually(predicate, attempts) do
    if predicate.() do
      true
    else
      Process.sleep(20)
      eventually(predicate, attempts - 1)
    end
  end

  defp in_temporary_directory(callback) do
    root =
      Path.join(
        System.tmp_dir!(),
        "synapse-workspace-phase-zero-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(root)

    try do
      callback.(root)
    after
      File.rm_rf!(root)
    end
  end
end
