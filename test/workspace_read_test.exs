defmodule Synapse.Workspace.ReadTest do
  use ExUnit.Case, async: false

  alias Synapse.Workspace

  alias Synapse.Workspace.{
    Access,
    Error,
    Limits,
    OpenRequest,
    OperationContext,
    Path,
    Platform,
    Reader,
    ReadLine,
    ReadRequest,
    ReadResult,
    Revision,
    RevisionAlgorithm,
    Root,
    MutationServer
  }

  @moduletag skip: not Platform.supported?()

  test "reads empty and one-line files with revisions" do
    in_temporary_directory(fn root ->
      File.write!(Elixir.Path.join(root, "empty.txt"), "")
      File.write!(Elixir.Path.join(root, "one.txt"), "one line")
      handle = open_workspace(root)

      assert {:ok,
              %ReadResult{
                path: "empty.txt",
                lines: [],
                next_line: nil,
                file_bytes: 0,
                revision: %Revision{}
              }} = read(handle, "empty.txt")

      assert {:ok,
              %ReadResult{
                lines: [
                  %ReadLine{number: 1, text: "one line", ending: :none, truncated: false}
                ],
                next_line: nil,
                file_bytes: 8
              }} = read(handle, "one.txt")

      Workspace.close(handle)
    end)
  end

  test "preserves LF, CRLF, mixed endings, empty lines, and no final newline" do
    in_temporary_directory(fn root ->
      File.write!(Elixir.Path.join(root, "endings.txt"), "one\ntwo\r\n\nthree")
      handle = open_workspace(root)

      assert {:ok, result} = read(handle, "endings.txt", line_count: 10)

      assert result.lines == [
               %ReadLine{number: 1, text: "one", ending: :lf, truncated: false},
               %ReadLine{number: 2, text: "two", ending: :crlf, truncated: false},
               %ReadLine{number: 3, text: "", ending: :lf, truncated: false},
               %ReadLine{number: 4, text: "three", ending: :none, truncated: false}
             ]

      assert result.next_line == nil
      assert result.file_bytes == byte_size("one\ntwo\r\n\nthree")
      Workspace.close(handle)
    end)
  end

  test "enforces default, lowered, and maximum line windows" do
    in_temporary_directory(fn root ->
      content = Enum.map_join(1..1_100, "", &"line-#{&1}\n")
      File.write!(Elixir.Path.join(root, "many.txt"), content)
      handle = open_workspace(root)

      assert {:ok, default} = read(handle, "many.txt")
      assert length(default.lines) == 100
      assert hd(default.lines).number == 1
      assert List.last(default.lines).number == 100
      assert default.next_line == 101

      assert {:ok, lowered} = read(handle, "many.txt", start_line: 501, line_count: 2)

      assert Enum.map(lowered.lines, &{&1.number, &1.text}) == [
               {501, "line-501"},
               {502, "line-502"}
             ]

      assert lowered.next_line == 503

      assert {:ok, maximum} =
               read(handle, "many.txt", line_count: 1_000, max_bytes: 65_536)

      assert length(maximum.lines) == 1_000
      assert maximum.next_line == 1_001

      assert {:ok, beyond_eof} = read(handle, "many.txt", start_line: 2_000, line_count: 10)
      assert beyond_eof.lines == []
      assert beyond_eof.next_line == nil
      Workspace.close(handle)
    end)
  end

  test "enforces byte windows independently and clips only at UTF-8 boundaries" do
    in_temporary_directory(fn root ->
      File.write!(Elixir.Path.join(root, "bytes.txt"), "alpha\nbeta\ngamma\n")
      File.write!(Elixir.Path.join(root, "unicode.txt"), "ééé\nnext\n")
      File.write!(Elixir.Path.join(root, "crlf.txt"), "abcdef\r\nnext\r\n")
      File.write!(Elixir.Path.join(root, "maximum.txt"), String.duplicate("x", 70_000))
      File.write!(Elixir.Path.join(root, "default.txt"), String.duplicate("d", 40_000))
      File.write!(Elixir.Path.join(root, "wide-utf8.txt"), "€😀x\nnext\n")
      File.write!(Elixir.Path.join(root, "empty-crlf.txt"), "\r\nnext")
      handle = open_workspace(root)

      assert {:ok, bounded} = read(handle, "bytes.txt", line_count: 10, max_bytes: 6)
      assert bounded.lines == [%ReadLine{number: 1, text: "alpha", ending: :lf, truncated: false}]
      assert bounded.next_line == 2

      assert {:ok, clipped} = read(handle, "unicode.txt", line_count: 10, max_bytes: 5)

      assert clipped.lines == [
               %ReadLine{number: 1, text: "éé", ending: :lf, truncated: true}
             ]

      assert clipped.next_line == 2

      assert {:ok, continuation} =
               read(handle, "unicode.txt", start_line: clipped.next_line, line_count: 10)

      assert Enum.map(continuation.lines, & &1.text) == ["next"]

      assert {:ok, crlf} = read(handle, "crlf.txt", max_bytes: 1)
      assert crlf.lines == [%ReadLine{number: 1, text: "a", ending: :crlf, truncated: true}]
      assert crlf.next_line == 2

      assert {:ok, maximum} = read(handle, "maximum.txt", max_bytes: 65_536)
      assert [%ReadLine{text: text, ending: :none, truncated: true}] = maximum.lines
      assert byte_size(text) == 65_536
      assert maximum.next_line == nil

      assert {:ok, default} = read(handle, "default.txt")
      assert [%ReadLine{text: default_text, truncated: true}] = default.lines
      assert byte_size(default_text) == 32_768
      assert :binary.referenced_byte_size(default_text) == byte_size(default_text)

      for {maximum_bytes, expected} <- [{1, ""}, {2, ""}, {3, "€"}, {4, "€"}, {6, "€"}, {7, "€😀"}] do
        assert {:ok, utf8} = read(handle, "wide-utf8.txt", max_bytes: maximum_bytes)
        assert [%ReadLine{text: ^expected, truncated: true, ending: :lf}] = utf8.lines
        assert utf8.next_line == 2
      end

      assert {:ok, empty_crlf} = read(handle, "empty-crlf.txt", max_bytes: 1)

      assert empty_crlf.lines == [
               %ReadLine{number: 1, text: "", ending: :crlf, truncated: true}
             ]

      assert empty_crlf.next_line == 2
      Workspace.close(handle)
    end)
  end

  test "rejects oversized files, invalid UTF-8, and unsupported file types" do
    in_temporary_directory(fn root ->
      File.write!(Elixir.Path.join(root, "maximum.txt"), String.duplicate("x", 16))
      File.write!(Elixir.Path.join(root, "too-large.txt"), String.duplicate("x", 17))
      File.write!(Elixir.Path.join(root, "invalid.txt"), <<255, 254>>)
      File.mkdir!(Elixir.Path.join(root, "directory"))
      {:ok, limits} = Limits.new(max_file_bytes: 16)
      handle = open_workspace(root, limits)

      assert {:ok, %ReadResult{file_bytes: 16}} = read(handle, "maximum.txt")

      assert {:error, %Error{kind: :limit, reason: :file_too_large}} =
               read(handle, "too-large.txt")

      assert {:error, %Error{kind: :invalid, reason: :invalid_utf8}} =
               read(handle, "invalid.txt")

      assert {:error, %Error{kind: :denied, reason: :not_regular_file}} =
               read(handle, "directory")

      Workspace.close(handle)
    end)
  end

  test "revisions are deterministic per observation and scoped by path and handle" do
    in_temporary_directory(fn root ->
      a_path = Elixir.Path.join(root, "a.txt")
      b_path = Elixir.Path.join(root, "b.txt")
      File.write!(a_path, "same")
      File.write!(b_path, "same")
      first_handle = open_workspace(root)
      second_handle = open_workspace(root)

      assert {:ok, first} = read(first_handle, "a.txt")
      assert {:ok, unchanged} = read(first_handle, "a.txt")
      assert first.revision == unchanged.revision
      assert {:ok, parsed_revision} = first.revision |> Revision.encode() |> Revision.parse()
      assert parsed_revision == first.revision

      assert {:ok, other_path} = read(first_handle, "b.txt")
      refute first.revision == other_path.revision

      assert {:ok, other_handle} = read(second_handle, "a.txt")
      refute first.revision == other_handle.revision

      stat = File.stat!(a_path)
      digest = :crypto.hash(:sha256, "same")

      assert MutationServer.revision_matches?(
               first_handle.state,
               first_handle.token,
               "a.txt",
               stat,
               digest,
               first.revision
             )

      refute MutationServer.revision_matches?(
               first_handle.state,
               first_handle.token,
               "b.txt",
               stat,
               digest,
               first.revision
             )

      refute MutationServer.revision_matches?(
               second_handle.state,
               second_handle.token,
               "a.txt",
               stat,
               digest,
               first.revision
             )

      File.write!(a_path, "changed")
      assert {:ok, changed} = read(first_handle, "a.txt")
      refute first.revision == changed.revision

      File.chmod!(a_path, 0o600)
      assert {:ok, changed_mode} = read(first_handle, "a.txt")
      refute changed.revision == changed_mode.revision

      File.touch!(a_path, {{2020, 1, 2}, {3, 4, 5}})
      assert {:ok, changed_time} = read(first_handle, "a.txt")
      refute changed_mode.revision == changed_time.revision

      parked = Elixir.Path.join(root, "parked.txt")
      File.rename!(a_path, parked)
      File.write!(a_path, "changed")
      File.chmod!(a_path, 0o600)
      assert {:ok, replaced_inode} = read(first_handle, "a.txt")
      refute changed_time.revision == replaced_inode.revision

      File.write!(Elixir.Path.join(root, "window.txt"), "visible\nhidden-a\n")
      assert {:ok, first_window} = read(first_handle, "window.txt", line_count: 1)
      File.write!(Elixir.Path.join(root, "window.txt"), "visible\nhidden-b\n")
      assert {:ok, changed_outside_window} = read(first_handle, "window.txt", line_count: 1)
      refute first_window.revision == changed_outside_window.revision

      malformed = %Revision{encoded: nil}

      refute MutationServer.revision_matches?(
               first_handle.state,
               first_handle.token,
               "a.txt",
               File.stat!(a_path),
               :crypto.hash(:sha256, "changed"),
               malformed
             )

      assert Process.alive?(first_handle.state)

      assert inspect(:sys.get_state(first_handle.state)) ==
               "#Synapse.Workspace.MutationServer<redacted>"

      status = inspect(:sys.get_status(first_handle.state))
      assert status =~ "redacted"
      refute status =~ root

      assert {:error, :invalid_revision} = Revision.parse("wsr1.invalid")
      Workspace.close(first_handle)
      Workspace.close(second_handle)
    end)
  end

  test "revision payload has a fixed vector and rejects noncanonical paths" do
    stat = %File.Stat{
      size: 5,
      type: :regular,
      access: :read_write,
      atime: {{2020, 1, 1}, {0, 0, 0}},
      mtime: {{2020, 1, 2}, {3, 4, 5}},
      ctime: {{2020, 1, 3}, {6, 7, 8}},
      mode: 33_188,
      links: 1,
      major_device: 1,
      minor_device: 2,
      inode: 3,
      uid: 4,
      gid: 5
    }

    key = :binary.copy(<<7>>, 32)
    digest = :crypto.hash(:sha256, "hello")
    assert {:ok, revision} = RevisionAlgorithm.calculate(key, "lib/a.txt", stat, digest)

    assert Revision.encode(revision) ==
             "wsr1.72eF_DQ0NT0NjCmyUPyX4fswVl-PoOuOhck61qiLbU4"

    for invalid <- ["/lib/a.txt", "lib/../a.txt", "lib//a.txt", <<255>>] do
      assert {:error, :invalid_revision_input} =
               RevisionAlgorithm.calculate(key, invalid, stat, digest)

      refute RevisionAlgorithm.matches?(revision, key, invalid, stat, digest)
    end

    refute RevisionAlgorithm.matches?(%Revision{encoded: nil}, key, "lib/a.txt", stat, digest)
  end

  test "authoritative handle state prevents raised access and limits" do
    in_temporary_directory(fn root ->
      File.write!(Elixir.Path.join(root, "file.txt"), String.duplicate("x", 32))
      {:ok, denied_access} = Access.new(read: false, write: false, exec: false)
      {:ok, broad_access} = Access.new(read: true, write: true, exec: true)
      {:ok, lowered_limits} = Limits.new(max_file_bytes: 16)

      {:ok, denied_request} =
        OpenRequest.new(
          root: root,
          owner: self(),
          limits: Limits.default(),
          access: denied_access
        )

      {:ok, denied_handle} = Workspace.open(denied_request)

      {:ok, denied_context} =
        OperationContext.new(operation_id: "denied-read", access: denied_access)

      assert {:error, %Error{reason: :access_denied}} =
               Workspace.read(denied_handle, read_request("file.txt"), denied_context)

      forged_access = %{denied_handle | access: broad_access}

      assert {:error, %Error{reason: :invalid_handle}} =
               Workspace.read(forged_access, read_request("file.txt"), context())

      lowered_handle = open_workspace(root, lowered_limits)
      forged_limits = %{lowered_handle | limits: Limits.default()}

      assert {:error, %Error{reason: :invalid_handle}} =
               Workspace.read(forged_limits, read_request("file.txt"), context())

      assert {:error, %Error{reason: :invalid_handle}} = Workspace.close(forged_access)
      assert {:error, %Error{reason: :invalid_handle}} = Workspace.close(forged_limits)
      assert :ok = Workspace.close(denied_handle)
      assert :ok = Workspace.close(lowered_handle)
    end)
  end

  test "detects descriptor metadata changes and final path replacement" do
    in_temporary_directory(fn root ->
      path = Elixir.Path.join(root, "race.txt")
      File.write!(path, "before")
      {:ok, root_state} = Root.open(root, Limits.default())
      {:ok, resolved} = Path.resolve(root_state, "race.txt", 4_096, :file)
      request = read_request("race.txt")
      operation_context = context()

      assert {:error, :file_changed} =
               Reader.read(resolved, request, operation_context, Limits.default(),
                 before_post_stat: fn ->
                   File.chmod!(path, 0o600)
                   :ok
                 end
               )

      File.chmod!(path, 0o644)
      handle = open_workspace(root)

      {:ok, resolved} =
        MutationServer.resolve(handle.state, handle.token, "race.txt", :file, false)

      parked = Elixir.Path.join(root, "race-parked.txt")

      assert {:ok, observation} =
               Reader.read(resolved, request, operation_context, Limits.default(),
                 before_post_stat: fn ->
                   File.rename!(path, parked)
                   File.write!(path, "before")
                   :ok
                 end
               )

      assert {:error, :file_changed} =
               MutationServer.confirm_revision(
                 handle.state,
                 handle.token,
                 "race.txt",
                 observation.stat,
                 observation.digest
               )

      Workspace.close(handle)
    end)
  end

  test "checks cancellation and file growth between bounded hash chunks" do
    in_temporary_directory(fn root ->
      path = Elixir.Path.join(root, "large.txt")
      File.write!(path, String.duplicate("x", 60_000))
      {:ok, limits} = Limits.new(max_file_bytes: 65_536)
      {:ok, root_state} = Root.open(root, limits)
      {:ok, resolved} = Path.resolve(root_state, "large.txt", 4_096, :file)
      request = read_request("large.txt")
      cancel_ref = make_ref()
      operation_context = context(cancel_ref: cancel_ref)

      assert {:error, :cancelled} =
               Reader.read(resolved, request, operation_context, limits,
                 after_chunk: fn ->
                   send(self(), {:cancel, cancel_ref})
                   :ok
                 end
               )

      {:ok, resolved} = Path.resolve(root_state, "large.txt", 4_096, :file)

      assert {:error, :file_too_large} =
               Reader.read(resolved, request, context(), limits,
                 after_chunk: fn ->
                   unless Process.get(:grew_file) do
                     Process.put(:grew_file, true)
                     File.write!(path, String.duplicate("y", 10_000), [:append])
                   end

                   :ok
                 end
               )

      Process.delete(:grew_file)
    end)
  end

  test "reports activity and handles sink failure, cancellation, deadlines, and closure" do
    in_temporary_directory(fn root ->
      File.write!(Elixir.Path.join(root, "file.txt"), "content\n")
      handle = open_workspace(root)

      activity_sink = fn operation_context ->
        send(self(), {:read_activity, operation_context.operation_id})
        :ok
      end

      assert {:ok, _result} =
               read(handle, "file.txt", [], context(activity_sink: activity_sink))

      assert_receive {:read_activity, "read-operation"}
      refute_receive {:read_activity, _operation_id}

      assert {:error, %Error{reason: :activity_sink_failed}} =
               read(handle, "file.txt", [], context(activity_sink: fn _context -> :invalid end))

      File.write!(Elixir.Path.join(root, "invalid.txt"), <<255>>)

      assert {:error, %Error{reason: :invalid_utf8} = invalid_error} =
               read(handle, "invalid.txt", [], context(activity_sink: activity_sink))

      refute_receive {:read_activity, _operation_id}
      refute inspect(invalid_error) =~ root

      assert {:error, %Error{reason: :deadline_elapsed}} =
               read(
                 handle,
                 "file.txt",
                 [],
                 context(deadline: System.monotonic_time(:millisecond) - 1)
               )

      cancel_ref = make_ref()
      send(self(), {:cancel, cancel_ref})

      assert {:error, %Error{kind: :cancelled, reason: :cancelled}} =
               read(handle, "file.txt", [], context(cancel_ref: cancel_ref))

      sink_cancel_ref = make_ref()

      cancelling_sink = fn _context ->
        send(self(), {:cancel, sink_cancel_ref})
        :ok
      end

      assert {:ok, _result} =
               read(
                 handle,
                 "file.txt",
                 [],
                 context(cancel_ref: sink_cancel_ref, activity_sink: cancelling_sink)
               )

      assert_receive {:cancel, ^sink_cancel_ref}

      other_ref = make_ref()
      send(self(), {:cancel, other_ref})
      assert {:ok, _result} = read(handle, "file.txt")
      assert_receive {:cancel, ^other_ref}

      assert :ok = Workspace.close(handle)

      assert {:error, %Error{reason: :invalid_handle}} =
               read(handle, "file.txt")
    end)
  end

  test "close waits for an admitted read blocked in its activity callback" do
    in_temporary_directory(fn root ->
      File.write!(Elixir.Path.join(root, "file.txt"), "content\n")
      handle = open_workspace(root)
      owner = self()

      activity_sink = fn _context ->
        send(owner, {:blocked_read_activity, self()})

        receive do
          :release_blocked_read -> :ok
        end
      end

      read_task =
        Task.async(fn ->
          read(
            handle,
            "file.txt",
            [],
            context(operation_id: "blocked-read", activity_sink: activity_sink)
          )
        end)

      assert_receive {:blocked_read_activity, read_process}
      close_task = Task.async(fn -> Workspace.close(handle) end)
      assert nil == Task.yield(close_task, 10)
      send(read_process, :release_blocked_read)
      assert {:ok, %ReadResult{}} = Task.await(read_task)
      assert :ok = Task.await(close_task, 10_000)
      refute Process.alive?(handle.state)
    end)
  end

  defp read(handle, path, request_options \\ [], operation_context \\ context()) do
    request = read_request(path, request_options)
    Workspace.read(handle, request, operation_context)
  end

  defp read_request(path, options \\ []) do
    {:ok, request} = ReadRequest.new(Keyword.put(options, :path, path))
    request
  end

  defp context(options \\ []) do
    {:ok, access} = Access.new(read: true, write: true, exec: true)

    options =
      options
      |> Keyword.put_new(:operation_id, "read-operation")
      |> Keyword.put_new(:access, access)

    {:ok, context} = OperationContext.new(options)
    context
  end

  defp open_workspace(root, limits \\ Limits.default()) do
    {:ok, access} = Access.new(read: true, write: true, exec: true)

    {:ok, request} =
      OpenRequest.new(root: root, owner: self(), limits: limits, access: access)

    {:ok, handle} = Workspace.open(request)
    handle
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
        "synapse-workspace-read-#{Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)}"
      )

    File.mkdir!(root)
    root
  end
end
