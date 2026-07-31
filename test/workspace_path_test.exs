defmodule Synapse.Workspace.PlatformTest do
  use ExUnit.Case, async: true

  alias Synapse.Workspace.Platform

  test "support is explicit for Darwin arm64 only" do
    assert Platform.supported?({:unix, :darwin}, ~c"aarch64-apple-darwin", {24, 6, 0})
    assert Platform.supported?({:unix, :darwin}, "arm64-apple-darwin", {25, 0, 0})
    refute Platform.supported?({:unix, :darwin}, "aarch64-apple-darwin", {24, 5, 0})
    refute Platform.supported?({:unix, :darwin}, "x86_64-apple-darwin", {25, 0, 0})
    refute Platform.supported?({:unix, :linux}, "aarch64-unknown-linux", {6, 0, 0})
  end
end

defmodule Synapse.Workspace.PathTest do
  use ExUnit.Case, async: false

  alias Synapse.Workspace

  alias Synapse.Workspace.{
    Access,
    EditRequest,
    Error,
    Handle,
    Limits,
    OpenRequest,
    OperationContext,
    Path,
    Platform,
    ProcessSpec,
    ReadRequest,
    Root,
    WriteRequest
  }

  @moduletag skip: not Platform.supported?()

  test "opens an existing readable root and closes idempotently" do
    in_temporary_directory(fn root ->
      assert {:ok, %Handle{} = handle} = open_workspace(root)
      assert inspect(handle) == "#Synapse.Workspace.Handle<opaque>"
      monitor = Process.monitor(handle.state)
      assert :ok = Workspace.close(handle)
      assert_receive {:DOWN, ^monitor, :process, _, :normal}, 1_000
      assert :ok = Workspace.close(handle)
    end)
  end

  test "rejects missing, regular-file, and unreadable roots without exposing them" do
    in_temporary_directory(fn root ->
      missing = Elixir.Path.join(root, "missing")
      file = Elixir.Path.join(root, "file")
      unreadable = Elixir.Path.join(root, "unreadable")
      File.write!(file, "file")
      File.mkdir!(unreadable)
      File.chmod!(unreadable, 0o000)
      on_exit(fn -> File.chmod(unreadable, 0o700) end)

      for invalid_root <- [missing, file, unreadable] do
        assert {:error, %Error{kind: :invalid, reason: :invalid_root} = error} =
                 open_workspace(invalid_root)

        refute inspect(error) =~ invalid_root
      end
    end)
  end

  test "resolves trusted root symlinks once and then uses the canonical target" do
    in_temporary_directory(fn parent ->
      target = Elixir.Path.join(parent, "target")
      link = Elixir.Path.join(parent, "root-link")
      File.mkdir!(target)
      File.write!(Elixir.Path.join(target, "inside.txt"), "inside")
      File.ln_s!(target, link)

      assert {:ok, handle} = open_workspace(link)
      File.rm!(link)

      assert {:ok, %Synapse.Workspace.ReadResult{path: "inside.txt"}} =
               Workspace.read(handle, read_request("inside.txt"), context())

      assert :ok = Workspace.close(handle)
    end)
  end

  test "resolves relative multi-hop root links and rejects broken roots and link loops" do
    in_temporary_directory(fn parent ->
      target = Elixir.Path.join(parent, "target")
      middle = Elixir.Path.join(parent, "middle")
      entry = Elixir.Path.join(parent, "entry")
      broken = Elixir.Path.join(parent, "broken")
      loop_a = Elixir.Path.join(parent, "loop-a")
      loop_b = Elixir.Path.join(parent, "loop-b")
      File.mkdir!(target)
      File.ln_s!("target", middle)
      File.ln_s!("middle", entry)
      File.ln_s!("missing", broken)
      File.ln_s!("loop-b", loop_a)
      File.ln_s!("loop-a", loop_b)

      assert {:ok, handle} = open_workspace(entry)
      assert :ok = Workspace.close(handle)

      for invalid <- [broken, loop_a] do
        assert {:error, %Error{reason: :invalid_root}} = open_workspace(invalid)
      end
    end)
  end

  test "interprets parent components after following root symlinks" do
    in_temporary_directory(fn parent ->
      target = Elixir.Path.join(parent, "target")
      nested = Elixir.Path.join(target, "nested")
      link = Elixir.Path.join(parent, "link")
      target_link = Elixir.Path.join(parent, "target-link")
      File.mkdir_p!(nested)
      File.write!(Elixir.Path.join(target, "allowed.txt"), "allowed")
      File.write!(Elixir.Path.join(parent, "broader.txt"), "broader")
      File.ln_s!("target/nested", link)
      File.ln_s!("target/nested/..", target_link)

      for root_path <- [Elixir.Path.join(link, ".."), target_link] do
        assert {:ok, handle} = open_workspace(root_path)

        assert {:ok, %Synapse.Workspace.ReadResult{path: "allowed.txt"}} =
                 Workspace.read(handle, read_request("allowed.txt"), context())

        assert {:error, %Error{reason: :not_found, path: "broader.txt"}} =
                 Workspace.read(handle, read_request("broader.txt"), context())

        assert :ok = Workspace.close(handle)
      end
    end)
  end

  test "renaming the canonical root makes the handle unavailable" do
    root = temporary_directory()
    renamed = root <> "-renamed"
    on_exit(fn -> File.rm_rf!(renamed) end)
    File.write!(Elixir.Path.join(root, "inside.txt"), "inside")

    assert {:ok, handle} = open_workspace(root)
    assert :ok = File.rename(root, renamed)
    assert :ok = File.mkdir(root)

    assert {:error, %Error{kind: :unavailable, reason: :invalid_root, path: "inside.txt"}} =
             Workspace.read(handle, read_request("inside.txt"), context())

    assert :ok = Workspace.close(handle)
  end

  test "pure path normalization rejects every ambiguous lexical form" do
    maximum = Limits.default().max_path_bytes

    assert {:ok, "lib/example.ex"} = Path.normalize("lib/example.ex", maximum)
    assert {:ok, "."} = Path.normalize(".", maximum, allow_dot: true)
    assert {:error, :empty_path} = Path.normalize("", maximum)
    assert {:error, :absolute_path} = Path.normalize("/tmp/outside", maximum)
    assert {:error, :path_traversal} = Path.normalize("../project-other/sentinel", maximum)
    assert {:error, :path_traversal} = Path.normalize("lib/../outside", maximum)
    assert {:error, :dot_component} = Path.normalize("lib/./example.ex", maximum)
    assert {:error, :empty_component} = Path.normalize("lib//example.ex", maximum)
    assert {:error, :empty_component} = Path.normalize("lib/", maximum)
    assert {:error, :nul_byte} = Path.normalize("lib/a\0b", maximum)
    assert {:error, :invalid_utf8} = Path.normalize(<<255>>, maximum)
    assert {:error, :path_too_long} = Path.normalize(String.duplicate("x", maximum + 1), maximum)
  end

  test "prefix-confusion traversal cannot reach an outside sibling" do
    in_temporary_directory(fn parent ->
      root = Elixir.Path.join(parent, "project")
      sibling = Elixir.Path.join(parent, "project-other")
      File.mkdir!(root)
      File.mkdir!(sibling)
      File.write!(Elixir.Path.join(sibling, "sentinel"), "outside")

      assert {:ok, root_state} = Root.open(root, Limits.default().max_path_bytes)

      assert {:error, :path_traversal} =
               Path.resolve(root_state, "../project-other/sentinel", 4_096, :file)

      assert File.read!(Elixir.Path.join(sibling, "sentinel")) == "outside"
    end)
  end

  test "rejects intermediate and final symlinks whether outside, contained, broken, or looping" do
    in_temporary_directory(fn parent ->
      root = Elixir.Path.join(parent, "root")
      outside = Elixir.Path.join(parent, "outside")
      File.mkdir!(root)
      File.mkdir!(outside)
      File.write!(Elixir.Path.join(root, "inside.txt"), "inside")
      File.write!(Elixir.Path.join(outside, "sentinel.txt"), "outside")
      File.ln_s!(outside, Elixir.Path.join(root, "outside-dir"))
      File.ln_s!("inside.txt", Elixir.Path.join(root, "inside-link"))

      File.ln_s!(
        Elixir.Path.join(outside, "sentinel.txt"),
        Elixir.Path.join(root, "outside-link")
      )

      File.ln_s!("missing.txt", Elixir.Path.join(root, "broken-link"))
      File.ln_s!("loop-b", Elixir.Path.join(root, "loop-a"))
      File.ln_s!("loop-a", Elixir.Path.join(root, "loop-b"))

      assert {:ok, handle} = open_workspace(root)

      for path <- [
            "outside-dir/sentinel.txt",
            "inside-link",
            "outside-link",
            "broken-link",
            "loop-a"
          ] do
        assert {:error, %Error{kind: :denied, reason: :symlink, path: ^path}} =
                 Workspace.read(handle, read_request(path), context())
      end

      {:ok, write} =
        WriteRequest.new(path: "outside-link", content: "new", expected_revision: :missing)

      assert {:error, %Error{reason: :symlink, path: "outside-link"}} =
               Workspace.write(handle, write, context())

      {:ok, edit} =
        EditRequest.new(
          path: "inside-link",
          old_text: "inside",
          new_text: "new",
          expected_revision: revision()
        )

      assert {:error, %Error{reason: :symlink, path: "inside-link"}} =
               Workspace.edit(handle, edit, context())

      {:ok, spec} =
        ProcessSpec.new(executable: "/bin/sh", cwd: "outside-dir", mutation: :read_only)

      assert {:error, %Error{reason: :symlink, path: "outside-dir"}} =
               Workspace.run(handle, spec, fn _event -> :ok end, context())

      assert File.read!(Elixir.Path.join(outside, "sentinel.txt")) == "outside"
      assert :ok = Workspace.close(handle)
    end)
  end

  test "rejects directories, FIFOs, Unix sockets, devices, and multiply linked files" do
    in_temporary_directory(fn root ->
      directory = Elixir.Path.join(root, "directory")
      fifo = Elixir.Path.join(root, "fifo")
      socket_path = Elixir.Path.join(root, "socket")
      original = Elixir.Path.join(root, "original")
      hard_link = Elixir.Path.join(root, "hard-link")
      File.mkdir!(directory)
      File.write!(original, "linked")
      File.ln!(original, hard_link)

      mkfifo = System.find_executable("mkfifo") || flunk("mkfifo is required on supported macOS")
      assert {"", 0} = System.cmd(mkfifo, [fifo])

      {:ok, socket} = :socket.open(:local, :stream)
      on_exit(fn -> :socket.close(socket) end)
      :ok = :socket.bind(socket, %{family: :local, path: socket_path})

      assert {:ok, handle} = open_workspace(root)

      for path <- ["directory", "fifo", "socket"] do
        assert {:error, %Error{reason: :not_regular_file, path: ^path}} =
                 Workspace.read(handle, read_request(path), context())
      end

      for path <- ["original", "hard-link"] do
        assert {:error, %Error{reason: :multiple_hard_links, path: ^path}} =
                 Workspace.read(handle, read_request(path), context())
      end

      assert :ok = Workspace.close(handle)
    end)

    dev_stat = File.lstat!("/dev")

    dev_root = %Root{
      canonical_path: "/dev",
      identity: {
        dev_stat.major_device,
        dev_stat.minor_device,
        dev_stat.inode,
        dev_stat.type
      },
      device: {dev_stat.major_device, dev_stat.minor_device}
    }

    assert {:error, :not_regular_file} = Path.resolve(dev_root, "null", 4_096, :file)

    assert {:error, %Error{kind: :unsupported, reason: :unsupported_filesystem}} =
             open_workspace("/dev")
  end

  test "rejects a device change below the root" do
    in_temporary_directory(fn root ->
      File.write!(Elixir.Path.join(root, "file"), "file")
      assert {:ok, root_state} = Root.open(root, 4_096)
      wrong_device = %{root_state | device: {-1, -1}}

      assert {:error, :mount_crossing} = Path.resolve(wrong_device, "file", 4_096, :file)
    end)
  end

  test "validates missing creation targets and process working directories" do
    in_temporary_directory(fn root ->
      File.mkdir!(Elixir.Path.join(root, "subdir"))
      assert {:ok, handle} = open_workspace(root)
      operation_context = context()

      {:ok, write} =
        WriteRequest.new(path: "new.txt", content: "new", expected_revision: :missing)

      assert {:ok, %Synapse.Workspace.MutationResult{path: "new.txt"}} =
               Workspace.write(handle, write, operation_context)

      assert File.read!(Elixir.Path.join(root, "new.txt")) == "new"

      {:ok, edit} =
        EditRequest.new(
          path: "missing.txt",
          old_text: "old",
          new_text: "new",
          expected_revision: revision()
        )

      assert {:error, %Error{reason: :stale_revision, path: "missing.txt"}} =
               Workspace.edit(handle, edit, operation_context)

      assert {:error, %Error{reason: :not_found, path: "missing.txt"}} =
               Workspace.read(handle, read_request("missing.txt"), operation_context)

      {:ok, nested_write} =
        WriteRequest.new(
          path: "missing-parent/new.txt",
          content: "new",
          expected_revision: :missing
        )

      assert {:error, %Error{reason: :not_found, path: "missing-parent/new.txt"}} =
               Workspace.write(handle, nested_write, operation_context)

      {:ok, spec} =
        ProcessSpec.new(executable: "/bin/sh", cwd: "subdir", mutation: :read_only)

      assert {:ok, %Synapse.Workspace.ProcessResult{termination: :exited, exit_code: 0}} =
               Workspace.run(handle, spec, fn _event -> :ok end, operation_context)

      {:ok, missing_cwd} =
        ProcessSpec.new(executable: "/bin/sh", cwd: "missing-dir", mutation: :read_only)

      assert {:error, %Error{reason: :not_found, path: "missing-dir"}} =
               Workspace.run(handle, missing_cwd, fn _event -> :ok end, operation_context)

      assert :ok = Workspace.close(handle)
    end)
  end

  test "monitors the opening owner, rejects forged tokens, and closes after owner death" do
    in_temporary_directory(fn root ->
      owner = spawn(fn -> Process.sleep(:infinity) end)
      assert {:ok, handle} = open_workspace(root, owner)
      root_owner_monitor = Process.monitor(handle.state)

      forged = %{handle | token: make_ref()}
      assert {:error, %Error{reason: :invalid_handle}} = Workspace.close(forged)
      assert Process.alive?(handle.state)

      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^root_owner_monitor, :process, _, :normal}, 1_000

      assert {:error, %Error{reason: :invalid_handle}} =
               Workspace.read(handle, read_request("missing"), context())

      assert :ok = Workspace.close(handle)
    end)
  end

  test "close does not report success for an unrelated live process" do
    in_temporary_directory(fn root ->
      assert {:ok, handle} = open_workspace(root)
      unrelated = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(unrelated, :kill) end)
      forged = %{handle | state: unrelated}

      assert {:error, %Error{reason: :invalid_handle}} = Workspace.close(forged)
      assert Process.alive?(unrelated)
      assert :ok = Workspace.close(handle)
    end)
  end

  test "documents the cooperative component-swap limitation and operation recheck" do
    in_temporary_directory(fn parent ->
      root = Elixir.Path.join(parent, "root")
      outside = Elixir.Path.join(parent, "outside")
      directory = Elixir.Path.join(root, "directory")
      parked = Elixir.Path.join(root, "parked")
      File.mkdir_p!(directory)
      File.mkdir!(outside)
      File.write!(Elixir.Path.join(directory, "sentinel"), "inside")
      File.write!(Elixir.Path.join(outside, "sentinel"), "outside")

      assert {:ok, root_state} = Root.open(root, 4_096)

      assert {:error, :symlink} =
               Path.resolve(root_state, "directory/sentinel", 4_096, :file,
                 before_revalidate: fn ->
                   File.rename!(directory, parked)
                   File.ln_s!(outside, directory)
                   :ok
                 end
               )

      File.rm!(directory)
      File.rename!(parked, directory)
      assert {:ok, resolved} = Path.resolve(root_state, "directory/sentinel", 4_096, :file)

      File.rename!(directory, parked)
      File.ln_s!(outside, directory)

      # Portable lstat validation does not pin components after it returns.
      assert File.read!(resolved.absolute) == "outside"

      assert {:ok, handle} = open_workspace(root)

      assert {:error, %Error{reason: :symlink}} =
               Workspace.read(handle, read_request("directory/sentinel"), context())

      assert :ok = Workspace.close(handle)
    end)
  end

  test "revalidates existing finals, missing finals, and same-type parent replacements" do
    in_temporary_directory(fn root ->
      file = Elixir.Path.join(root, "file")
      old_file = Elixir.Path.join(root, "old-file")
      missing = Elixir.Path.join(root, "missing")
      directory = Elixir.Path.join(root, "directory")
      old_directory = Elixir.Path.join(root, "old-directory")
      File.write!(file, "old")
      File.mkdir!(directory)
      File.write!(Elixir.Path.join(directory, "file"), "old")
      assert {:ok, root_state} = Root.open(root, 4_096)

      assert {:error, :io} =
               Path.resolve(root_state, "file", 4_096, :file,
                 before_revalidate: fn ->
                   File.rename!(file, old_file)
                   File.write!(file, "replacement")
                   :ok
                 end
               )

      assert {:error, :io} =
               Path.resolve(root_state, "missing", 4_096, :file,
                 allow_missing: true,
                 before_revalidate: fn ->
                   File.write!(missing, "appeared")
                   :ok
                 end
               )

      assert {:error, :io} =
               Path.resolve(root_state, "directory/file", 4_096, :file,
                 before_revalidate: fn ->
                   File.rename!(directory, old_directory)
                   File.mkdir!(directory)
                   File.write!(Elixir.Path.join(directory, "file"), "replacement")
                   :ok
                 end
               )
    end)
  end

  test "repeated cooperative parent symlink swaps fail before the trust point" do
    in_temporary_directory(fn parent ->
      for iteration <- 1..20 do
        root = Elixir.Path.join(parent, "root-#{iteration}")
        outside = Elixir.Path.join(parent, "outside-#{iteration}")
        directory = Elixir.Path.join(root, "directory")
        parked = Elixir.Path.join(root, "parked")
        File.mkdir_p!(directory)
        File.mkdir!(outside)
        File.write!(Elixir.Path.join(directory, "sentinel"), "inside")
        File.write!(Elixir.Path.join(outside, "sentinel"), "outside")
        assert {:ok, root_state} = Root.open(root, 4_096)

        assert {:error, :symlink} =
                 Path.resolve(root_state, "directory/sentinel", 4_096, :file,
                   before_revalidate: fn ->
                     File.rename!(directory, parked)
                     File.ln_s!(outside, directory)
                     :ok
                   end
                 )

        assert File.read!(Elixir.Path.join(outside, "sentinel")) == "outside"
      end
    end)
  end

  defp open_workspace(root, owner \\ self()) do
    {:ok, access} = Access.new(read: true, write: true, exec: true)

    {:ok, request} =
      OpenRequest.new(root: root, owner: owner, limits: Limits.default(), access: access)

    Workspace.open(request)
  end

  defp read_request(path) do
    {:ok, request} = ReadRequest.new(path: path)
    request
  end

  defp context do
    {:ok, access} = Access.new(read: true, write: true, exec: true)
    {:ok, context} = OperationContext.new(operation_id: "phase-2", access: access)
    context
  end

  defp revision do
    {:ok, revision} = Synapse.Workspace.Revision.from_mac(:crypto.hash(:sha256, "phase-2"))
    revision
  end

  defp in_temporary_directory(fun) do
    root = temporary_directory()

    try do
      fun.(root)
    after
      File.rm_rf!(root)
    end
  end

  defp temporary_directory do
    root =
      Elixir.Path.join(
        System.tmp_dir!(),
        "synapse-workspace-path-#{Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)}"
      )

    File.mkdir!(root)
    root
  end
end
