defmodule Synapse.Workspace.FacadeTest do
  use ExUnit.Case, async: true

  alias Synapse.Workspace

  alias Synapse.Workspace.{
    Access,
    EditRequest,
    Error,
    Handle,
    Limits,
    MutationResult,
    OpenRequest,
    OperationContext,
    ProcessEvent,
    ProcessResult,
    ProcessSpec,
    ReadLine,
    ReadRequest,
    ReadResult,
    Revision,
    WriteRequest
  }

  defmodule TestBackend do
    @behaviour Synapse.Workspace.Backend

    @impl true
    def workspace_backend?, do: true

    @impl true
    def valid_handle?(_handle), do: true

    @impl true
    def close(handle) do
      send(handle.state, {:closed, handle.token})
      :ok
    end

    @impl true
    def read(handle, request, context) do
      send(handle.state, {:read, request, context})

      {:ok, line} =
        ReadLine.new(number: request.start_line, text: "ok", ending: :none, truncated: false)

      {:ok, result} =
        ReadResult.new(
          path: request.path,
          revision: revision(),
          lines: [line],
          next_line: nil,
          file_bytes: 2
        )

      {:ok, result}
    end

    @impl true
    def write(handle, request, context) do
      send(handle.state, {:write, request, context})
      mutation(request.path, request.expected_revision, context.operation_id, request.content)
    end

    @impl true
    def edit(handle, request, context) do
      send(handle.state, {:edit, request, context})
      mutation(request.path, request.expected_revision, context.operation_id, request.new_text)
    end

    @impl true
    def run(handle, spec, event_sink, context) do
      send(handle.state, {:run, spec, context})
      {:ok, started} = ProcessEvent.Started.new(operation_id: context.operation_id)

      {:ok, output} =
        ProcessEvent.Output.new(operation_id: context.operation_id, sequence: 1, data: "ok")

      :ok = event_sink.(started)
      :ok = event_sink.(output)

      ProcessResult.new(
        operation_id: context.operation_id,
        termination: :exited,
        exit_code: 0,
        output: "ok",
        output_bytes: 2,
        truncated: false,
        elapsed_ms: 1
      )
    end

    defp mutation(path, previous_revision, operation_id, content) do
      MutationResult.new(
        operation_id: operation_id,
        path: path,
        previous_revision: previous_revision,
        revision: revision(),
        bytes_written: byte_size(content),
        changed: true,
        diff: "+#{content}\n",
        diff_truncated: false
      )
    end

    defp revision do
      {:ok, revision} = Revision.from_mac(:crypto.hash(:sha256, "facade-backend"))
      revision
    end
  end

  defmodule InvalidBackend do
    def workspace_backend?, do: true
    def valid_handle?(_handle), do: true
    def read(_handle, _request, _context), do: {:ok, :not_a_read_result}
    def write(_handle, _request, _context), do: raise("backend failure")
  end

  defmodule MismatchedBackend do
    def workspace_backend?, do: true
    def valid_handle?(_handle), do: true

    def read(_handle, request, context) do
      if request.path == "wrong-error" do
        Error.new(
          kind: :invalid,
          reason: :invalid_request,
          operation: :write,
          message: "Wrong operation",
          operation_id: context.operation_id,
          outcome: :not_applied
        )
        |> then(fn {:ok, error} -> {:error, error} end)
      else
        {:ok, line} =
          ReadLine.new(
            number: request.start_line,
            text: "too much",
            ending: :none,
            truncated: false
          )

        ReadResult.new(
          path: "different.txt",
          revision: revision(),
          lines: [line],
          next_line: nil,
          file_bytes: 8
        )
      end
    end

    def write(_handle, request, _context) do
      MutationResult.new(
        operation_id: "wrong-operation",
        path: request.path,
        previous_revision: request.expected_revision,
        revision: revision(),
        bytes_written: byte_size(request.content),
        changed: true,
        diff: "+new\n",
        diff_truncated: false
      )
    end

    def run(_handle, spec, _sink, context) do
      if spec.mutation == :unknown do
        ProcessResult.new(
          operation_id: context.operation_id,
          termination: :timed_out,
          exit_code: nil,
          output: "",
          output_bytes: 0,
          truncated: false,
          elapsed_ms: 1
        )
      else
        ProcessResult.new(
          operation_id: context.operation_id,
          termination: :exited,
          exit_code: 0,
          output: "too large",
          output_bytes: 9,
          truncated: false,
          elapsed_ms: 2_000
        )
      end
    end

    defp revision do
      {:ok, revision} = Revision.from_mac(:crypto.hash(:sha256, "mismatched-backend"))
      revision
    end
  end

  defmodule InvalidEventBackend do
    def workspace_backend?, do: true
    def valid_handle?(_handle), do: true

    def run(_handle, _spec, event_sink, context) do
      invalid = %ProcessEvent.Output{
        operation_id: context.operation_id,
        sequence: 1,
        data: "output-before-start"
      }

      :ok = event_sink.(invalid)

      ProcessResult.new(
        operation_id: context.operation_id,
        termination: :exited,
        exit_code: 0,
        output: "",
        output_bytes: 0,
        truncated: false,
        elapsed_ms: 1
      )
    end
  end

  test "open validates trusted input and returns the real opaque handle" do
    access = access(read: true, write: true, exec: true)

    assert {:ok, request} =
             OpenRequest.new(root: ".", owner: self(), limits: Limits.default(), access: access)

    assert {:ok, %Handle{} = handle} = Workspace.open(request)
    assert :ok = Workspace.close(handle)

    assert {:error, %Error{kind: :invalid, reason: :invalid_request}} = Workspace.open(%{})
  end

  test "opaque handles dispatch all operations and redact backend state" do
    handle = handle(access(read: true, write: true, exec: true))
    context = context(access(read: true, write: true, exec: true))
    revision = revision()

    assert inspect(handle) == "#Synapse.Workspace.Handle<opaque>"
    refute inspect(handle) =~ inspect(self())

    assert :ok = Workspace.close(handle)
    assert_receive {:closed, token}
    assert token == handle.token

    {:ok, read_request} = ReadRequest.new(path: "README.md")

    assert {:ok, %ReadResult{lines: [%ReadLine{text: "ok"}]}} =
             Workspace.read(handle, read_request, context)

    assert_receive {:read, ^read_request, ^context}

    {:ok, write_request} =
      WriteRequest.new(path: "new.txt", content: "new", expected_revision: :missing)

    assert {:ok, %MutationResult{previous_revision: :missing}} =
             Workspace.write(handle, write_request, context)

    assert_receive {:write, ^write_request, ^context}

    {:ok, edit_request} =
      EditRequest.new(
        path: "new.txt",
        old_text: "new",
        new_text: "updated",
        expected_revision: revision
      )

    assert {:ok, %MutationResult{previous_revision: ^revision}} =
             Workspace.edit(handle, edit_request, context)

    assert_receive {:edit, ^edit_request, ^context}

    {:ok, spec} =
      ProcessSpec.new(
        executable: "/bin/bash",
        arguments: ["-lc", "printf ok"],
        mutation: :unknown
      )

    sink = fn event ->
      send(self(), {:event, event})
      :ok
    end

    assert {:ok, %ProcessResult{termination: :exited, output: "ok"}} =
             Workspace.run(handle, spec, sink, context)

    assert_receive {:run, ^spec, ^context}
    assert_receive {:event, %ProcessEvent.Started{operation_id: "facade-1"}}
    assert_receive {:event, %ProcessEvent.Output{sequence: 1, data: "ok"}}
  end

  test "facade revalidates malformed structs before backend dispatch" do
    handle = handle(access(read: true, write: true, exec: false))
    context = context(access(read: true, write: false, exec: false))

    malformed = %ReadRequest{
      path: "../outside",
      start_line: 1,
      line_count: 1,
      max_bytes: 10
    }

    assert {:error, %Error{kind: :invalid, reason: :invalid_request, operation: :read}} =
             Workspace.read(handle, malformed, context)

    refute_receive {:read, _, _}
  end

  test "facade enforces handle and reduced operation access" do
    handle = handle(access(read: true, write: false, exec: false))
    context = context(access(read: true, write: false, exec: false))

    {:ok, write_request} =
      WriteRequest.new(path: "new.txt", content: "new", expected_revision: :missing)

    assert {:error,
            %Error{
              kind: :denied,
              reason: :access_denied,
              operation: :write,
              outcome: :not_applied
            }} = Workspace.write(handle, write_request, context)

    invalid_handle = %Handle{backend: nil, state: nil, token: nil, limits: nil, access: nil}
    assert {:error, %Error{reason: :invalid_handle}} = Workspace.close(invalid_handle)
    refute_receive {:write, _, _}
  end

  test "malformed contexts and backend failures remain structured data" do
    access = access(read: true, write: true, exec: false)
    handle = handle(access)
    {:ok, request} = ReadRequest.new(path: "README.md")

    malformed_context = %OperationContext{
      operation_id: String.duplicate("x", 257),
      access: access,
      cancel_ref: nil,
      deadline: :infinity,
      activity_sink: nil
    }

    assert {:error, %Error{reason: :invalid_request, operation_id: nil}} =
             Workspace.read(handle, request, malformed_context)

    invalid_backend_handle = %{handle | backend: InvalidBackend}
    context = context(access)

    assert {:error, %Error{kind: :unavailable, reason: :backend_unavailable}} =
             Workspace.read(invalid_backend_handle, request, context)

    {:ok, write_request} =
      WriteRequest.new(path: "new.txt", content: "new", expected_revision: :missing)

    assert {:error, %Error{kind: :ambiguous, outcome: :unknown}} =
             Workspace.write(invalid_backend_handle, write_request, context)

    arbitrary_handle = %{handle | backend: File}
    assert {:error, %Error{reason: :invalid_handle}} = Workspace.close(arbitrary_handle)
  end

  test "facade correlates results and errors with lowered requests and context" do
    access = access(read: true, write: true, exec: true)
    handle = %{handle(access) | backend: MismatchedBackend}
    context = context(access)

    {:ok, read_request} = ReadRequest.new(path: "README.md", line_count: 1, max_bytes: 2)

    assert {:error, %Error{kind: :unavailable, reason: :backend_unavailable}} =
             Workspace.read(handle, read_request, context)

    {:ok, error_request} = ReadRequest.new(path: "wrong-error")

    assert {:error, %Error{kind: :unavailable, reason: :backend_unavailable}} =
             Workspace.read(handle, error_request, context)

    {:ok, write_request} =
      WriteRequest.new(path: "new.txt", content: "new", expected_revision: :missing)

    assert {:error, %Error{kind: :ambiguous, outcome: :unknown}} =
             Workspace.write(handle, write_request, context)

    {:ok, spec} =
      ProcessSpec.new(
        executable: "/bin/sh",
        mutation: :read_only,
        max_output_bytes: 2,
        timeout_ms: 5
      )

    assert {:error, %Error{kind: :unavailable, reason: :backend_unavailable}} =
             Workspace.run(handle, spec, fn _event -> :ok end, context)

    {:ok, unknown_spec} =
      ProcessSpec.new(executable: "/bin/sh", mutation: :unknown, timeout_ms: 5)

    assert {:error, %Error{kind: :ambiguous, reason: :backend_unavailable, outcome: :unknown}} =
             Workspace.run(handle, unknown_spec, fn _event -> :ok end, context)
  end

  test "facade validates process events before delivering them" do
    access = access(read: false, write: false, exec: true)
    handle = %{handle(access) | backend: InvalidEventBackend}
    context = context(access)
    {:ok, spec} = ProcessSpec.new(executable: "/bin/sh", mutation: :read_only)

    sink = fn event ->
      send(self(), {:invalid_event_delivered, event})
      :ok
    end

    assert {:error, %Error{kind: :unavailable, reason: :backend_unavailable}} =
             Workspace.run(handle, spec, sink, context)

    refute_receive {:invalid_event_delivered, _event}
  end

  defp handle(access) do
    %Handle{
      backend: TestBackend,
      state: self(),
      token: make_ref(),
      limits: Limits.default(),
      access: access
    }
  end

  defp context(access) do
    {:ok, context} = OperationContext.new(operation_id: "facade-1", access: access)
    context
  end

  defp access(overrides) do
    {:ok, access} = Access.new(overrides)
    access
  end

  defp revision do
    {:ok, revision} = Revision.from_mac(:crypto.hash(:sha256, "facade-request"))
    revision
  end
end
