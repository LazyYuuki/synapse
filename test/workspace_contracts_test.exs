defmodule Synapse.Workspace.ContractsTest do
  use ExUnit.Case, async: true

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

  doctest ReadRequest
  doctest Synapse.Workspace.Fake

  describe "trusted core contracts" do
    test "access is explicit, boolean, and can only be reduced" do
      assert {:ok, ceiling} = Access.new(read: true, write: true, exec: false)
      assert {:ok, reduced} = Access.new(read: true, write: false, exec: false)
      assert Access.within?(reduced, ceiling)
      refute Access.within?(%Access{read: true, write: false, exec: true}, ceiling)
      refute Access.valid?(%Access{read: :yes, write: false, exec: false})
      assert {:error, {:read, :must_be_boolean}} = Access.new(write: false, exec: false)

      assert {:error, {:unknown_fields, [:shell]}} =
               Access.new(read: true, write: false, exec: false, shell: true)
    end

    test "limits match Phase 0 defaults and cannot exceed hard ceilings" do
      %Limits{} = limits = Limits.default()

      assert limits.max_file_bytes == 8_388_608
      assert limits.max_diff_bytes == 32_768
      assert limits.max_process_event_bytes == 16_384
      assert limits.max_process_output_bytes == 1_048_576
      assert Limits.valid?(limits)

      assert {:error, {:max_file_bytes, :must_be_reasonable_positive_integer}} =
               Limits.new(max_file_bytes: limits.max_file_bytes + 1)

      assert {:error, {:default_read_lines, :must_not_exceed_related_maximum}} =
               Limits.new(max_read_lines: 10)

      refute Limits.valid?(%Limits{limits | max_path_bytes: 0})
    end

    test "open and operation context revalidate nested structs" do
      %Limits{} = limits = Limits.default()
      {:ok, access} = Access.new(read: true, write: false, exec: false)

      assert {:ok, request} =
               OpenRequest.new(root: ".", owner: self(), limits: limits, access: access)

      assert request.owner == self()

      assert {:error, {:owner, :must_be_pid}} =
               OpenRequest.new(root: ".", owner: make_ref(), limits: limits, access: access)

      assert {:error, {:limits, :must_be_workspace_limits}} =
               OpenRequest.new(
                 root: ".",
                 owner: self(),
                 limits: %Limits{limits | max_file_bytes: 0},
                 access: access
               )

      assert {:ok, context} =
               OperationContext.new(operation_id: "tool-1", access: access)

      assert context.deadline == :infinity
      assert context.cancel_ref == nil

      assert {:error, {:access, :must_be_workspace_access}} =
               OperationContext.new(
                 operation_id: "tool-1",
                 access: %Access{read: :yes, write: false, exec: false}
               )

      assert {:error, {:operation_id, :must_be_bounded_non_empty_string}} =
               OperationContext.new(operation_id: String.duplicate("x", 257), access: access)

      assert {:error, {:cancel_ref, :must_be_reference_or_nil}} =
               OperationContext.new(operation_id: "tool-1", access: access, cancel_ref: "ref")

      assert {:error, {:deadline, :must_be_monotonic_time_or_infinity}} =
               OperationContext.new(
                 operation_id: "tool-1",
                 access: access,
                 deadline: 10_000_000_000_000_000_000
               )

      assert {:error, {:activity_sink, :must_be_arity_one_function_or_nil}} =
               OperationContext.new(operation_id: "tool-1", access: access, activity_sink: self())
    end

    test "revisions round-trip and redact their HMAC" do
      mac = :crypto.hash(:sha256, "phase-1")
      assert {:ok, revision} = Revision.from_mac(mac)
      assert {:ok, ^revision} = revision |> Revision.encode() |> Revision.parse()
      assert Revision.valid?(revision)
      assert inspect(revision) == "#Synapse.Workspace.Revision<redacted>"
      refute inspect(revision) =~ Base.url_encode64(mac, padding: false)
      assert {:error, :invalid_revision} = Revision.parse("wsr1.invalid")
      assert {:error, :invalid_revision} = Revision.parse("other.invalid")

      assert {:error, :invalid_revision} =
               Revision.parse("wsr1." <> String.duplicate("A", 42) <> "B")

      assert {:error, :invalid_revision} =
               Revision.parse("wsr1." <> String.duplicate("A", 10_000))
    end
  end

  describe "file contracts" do
    test "read requests apply defaults and reject escaped or oversized windows" do
      assert {:ok, request} = ReadRequest.new(path: "lib/synapse.ex")
      assert request.start_line == 1
      assert request.line_count == 100
      assert request.max_bytes == 32_768

      assert {:error, {:path, :must_be_bounded_relative_path}} =
               ReadRequest.new(path: "../secret")

      assert {:error, {:path, :must_be_bounded_relative_path}} =
               ReadRequest.new(path: "/tmp/secret")

      assert {:error, {:line_count, :must_be_within_workspace_limit}} =
               ReadRequest.new(path: "README.md", line_count: 1_001)
    end

    test "read lines and aggregate results remain bounded structured UTF-8" do
      revision = revision()
      assert {:ok, line} = ReadLine.new(number: 7, text: "hello", ending: :crlf, truncated: false)

      assert {:ok, result} =
               ReadResult.new(
                 path: "README.md",
                 revision: revision,
                 lines: [line],
                 next_line: 8,
                 file_bytes: 100
               )

      assert result.lines == [line]

      assert {:error, {:text, :must_be_bounded_utf8}} =
               ReadLine.new(number: 1, text: <<255>>, ending: :none, truncated: false)

      invalid_line = %ReadLine{number: 0, text: "", ending: :none, truncated: false}

      assert {:error, {:lines, :must_be_bounded_read_lines}} =
               ReadResult.new(
                 path: "README.md",
                 revision: revision,
                 lines: [invalid_line],
                 next_line: nil,
                 file_bytes: 0
               )

      {:ok, line_nine} = ReadLine.new(number: 9, text: "later", ending: :none, truncated: false)

      assert {:error, {:lines, :must_be_bounded_read_lines}} =
               ReadResult.new(
                 path: "README.md",
                 revision: revision,
                 lines: [line, line_nine],
                 next_line: nil,
                 file_bytes: 100
               )

      {:ok, truncated} =
        ReadLine.new(number: 7, text: "clipped", ending: :lf, truncated: true)

      assert {:ok, %ReadResult{next_line: 8}} =
               ReadResult.new(
                 path: "README.md",
                 revision: revision,
                 lines: [truncated],
                 next_line: 8,
                 file_bytes: 100
               )

      assert {:error, {:next_line, :must_follow_returned_lines}} =
               ReadResult.new(
                 path: "README.md",
                 revision: revision,
                 lines: [line],
                 next_line: 10,
                 file_bytes: 100
               )

      assert {:error, {:file_bytes, :must_be_within_workspace_limit}} =
               ReadResult.new(
                 path: "README.md",
                 revision: revision,
                 lines: [line],
                 next_line: 8,
                 file_bytes: 1
               )
    end

    test "write and edit require explicit valid revisions and bounded UTF-8" do
      revision = revision()

      assert {:ok, create} =
               WriteRequest.new(path: "new.txt", content: "new", expected_revision: :missing)

      assert create.expected_revision == :missing

      assert {:ok, edit} =
               EditRequest.new(
                 path: "new.txt",
                 old_text: "new",
                 new_text: "updated",
                 expected_revision: revision
               )

      assert edit.expected_revision == revision

      assert {:error, {:expected_revision, :must_be_missing_or_revision}} =
               WriteRequest.new(path: "new.txt", content: "new", expected_revision: nil)

      assert {:error, {:path, :must_be_bounded_relative_path}} =
               WriteRequest.new(
                 path: "bad\npath.txt",
                 content: "new",
                 expected_revision: :missing
               )

      assert {:error, {:old_text, :must_be_bounded_non_empty_utf8}} =
               EditRequest.new(
                 path: "new.txt",
                 old_text: "",
                 new_text: "updated",
                 expected_revision: revision
               )

      assert {:ok, %EditRequest{old_text: " "}} =
               EditRequest.new(
                 path: "new.txt",
                 old_text: " ",
                 new_text: "",
                 expected_revision: revision
               )
    end

    test "mutation results separate diff and file ceilings" do
      revision = revision()

      assert {:ok, result} =
               MutationResult.new(
                 operation_id: "write-1",
                 path: "new.txt",
                 previous_revision: :missing,
                 revision: revision,
                 bytes_written: 3,
                 changed: true,
                 diff: "+new\n",
                 diff_truncated: false
               )

      assert result.changed

      assert {:error, {:diff, :must_be_bounded_utf8}} =
               MutationResult.new(
                 operation_id: "write-1",
                 path: "new.txt",
                 previous_revision: :missing,
                 revision: revision,
                 bytes_written: 3,
                 changed: true,
                 diff: String.duplicate("x", 32_769),
                 diff_truncated: true
               )

      assert {:error, {:changed, :must_match_result}} =
               MutationResult.new(
                 operation_id: "write-1",
                 path: "new.txt",
                 previous_revision: revision,
                 revision: revision,
                 bytes_written: 1,
                 changed: false,
                 diff: "",
                 diff_truncated: false
               )

      assert {:error, {:changed, :must_match_result}} =
               MutationResult.new(
                 operation_id: "write-1",
                 path: "new.txt",
                 previous_revision: revision,
                 revision: revision,
                 bytes_written: 3,
                 changed: true,
                 diff: "+new\n",
                 diff_truncated: false
               )
    end
  end

  describe "process and error contracts" do
    test "process specifications require absolute executable plus separate argv" do
      assert {:ok, spec} =
               ProcessSpec.new(
                 executable: "/bin/bash",
                 arguments: ["-lc", "printf ok"],
                 mutation: :unknown
               )

      assert spec.cwd == "."
      assert spec.arguments == ["-lc", "printf ok"]

      assert {:error, {:executable, :must_be_bounded_absolute_path}} =
               ProcessSpec.new(executable: "bash", arguments: [], mutation: :unknown)

      assert {:error, {:arguments, :must_be_bounded_utf8_arguments}} =
               ProcessSpec.new(
                 executable: "/bin/bash",
                 arguments: [<<255>>],
                 mutation: :unknown
               )

      improper_arguments = ["-lc" | "not-a-list"]

      assert {:error, {:arguments, :must_be_bounded_utf8_arguments}} =
               ProcessSpec.new(
                 executable: "/bin/bash",
                 arguments: improper_arguments,
                 mutation: :unknown
               )
    end

    test "events permit arbitrary bounded output bytes and results enforce accounting" do
      assert {:ok, started} = ProcessEvent.Started.new(operation_id: "run-1")
      assert started.operation_id == "run-1"

      assert {:ok, output} =
               ProcessEvent.Output.new(operation_id: "run-1", sequence: 1, data: <<0, 255>>)

      assert output.data == <<0, 255>>

      assert {:error, {:operation_id, :must_be_bounded_non_empty_string}} =
               ProcessEvent.Started.new(operation_id: String.duplicate("x", 257))

      assert {:error, {:sequence, :must_be_positive_integer}} =
               ProcessEvent.Output.new(
                 operation_id: "run-1",
                 sequence: 10_000_000_000_000_000_000,
                 data: ""
               )

      assert {:error, {:data, :must_be_bounded_binary}} =
               ProcessEvent.Output.new(
                 operation_id: "run-1",
                 sequence: 1,
                 data: :binary.copy("x", 16_385)
               )

      assert {:ok, result} =
               ProcessResult.new(
                 operation_id: "run-1",
                 termination: :exited,
                 exit_code: 7,
                 output: <<0, 255>>,
                 output_bytes: 2,
                 truncated: false,
                 elapsed_ms: 10
               )

      assert result.exit_code == 7

      assert {:error, {:exit_code, :must_match_termination}} =
               ProcessResult.new(
                 operation_id: "run-1",
                 termination: :cancelled,
                 exit_code: 7,
                 output: "",
                 output_bytes: 0,
                 truncated: false,
                 elapsed_ms: 10
               )

      assert {:error, {:output_bytes, :must_cover_retained_output}} =
               ProcessResult.new(
                 operation_id: "run-1",
                 termination: :exited,
                 exit_code: 0,
                 output: "retained",
                 output_bytes: 1,
                 truncated: false,
                 elapsed_ms: 10
               )

      assert {:error, {:truncated, :must_match_output}} =
               ProcessResult.new(
                 operation_id: "run-1",
                 termination: :output_limit,
                 exit_code: nil,
                 output: "full",
                 output_bytes: 4,
                 truncated: false,
                 elapsed_ms: 10
               )

      assert {:ok, %ProcessResult{termination: :exited, truncated: true}} =
               ProcessResult.new(
                 operation_id: "run-1",
                 termination: :exited,
                 exit_code: 0,
                 output: "",
                 output_bytes: 1,
                 truncated: true,
                 elapsed_ms: 10
               )
    end

    test "errors reject unknown enums, absolute paths, and sensitive detail keys" do
      attrs = [
        kind: :conflict,
        reason: :stale_revision,
        operation: :write,
        message: "File changed after it was read",
        operation_id: "write-1",
        path: "lib/synapse.ex",
        outcome: :not_applied,
        details: %{"current_revision" => "available"}
      ]

      assert {:ok, error} = Error.new(attrs)
      assert error.kind == :conflict

      assert {:error, {:kind, :must_be_known}} = Error.new(Keyword.put(attrs, :kind, :oops))

      assert {:error, {:path, :must_be_bounded_relative_path_or_nil}} =
               Error.new(Keyword.put(attrs, :path, "/private/root/file"))

      assert {:error, {:details, :must_be_bounded_safe_json_object}} =
               Error.new(Keyword.put(attrs, :details, %{"command_output" => "secret"}))

      assert {:error, {:details, :must_be_bounded_safe_json_object}} =
               Error.new(Keyword.put(attrs, :details, %{"stage" => <<255>>}))

      nested_entries = Enum.map(1..32, fn _index -> %{"stage" => %{}} end)

      assert {:error, {:details, :must_be_bounded_safe_json_object}} =
               Error.new(Keyword.put(attrs, :details, %{"stage" => nested_entries}))

      improper_details = %{"stage" => ["read" | "invalid"]}

      assert {:error, {:details, :must_be_bounded_safe_json_object}} =
               Error.new(Keyword.put(attrs, :details, improper_details))

      assert {:error, {:details, :must_be_bounded_safe_json_object}} =
               Error.new(
                 Keyword.put(attrs, :details, %{"stage" => %{"command_output" => "secret"}})
               )

      assert {:error, {:outcome, :must_match_kind}} =
               Error.new(
                 kind: :ambiguous,
                 reason: :durability_unknown,
                 operation: :write,
                 message: "Mutation durability is unknown",
                 outcome: :not_applied
               )
    end
  end

  test "attribute constructors reject unknown fields and improper keyword lists" do
    access = access()
    revision = revision()

    constructors = [
      {Limits, %{}},
      {OpenRequest, %{root: ".", owner: self(), limits: Limits.default(), access: access}},
      {OperationContext, %{operation_id: "op", access: access}},
      {ReadRequest, %{path: "a"}},
      {ReadLine, %{number: 1, text: "", ending: :none, truncated: false}},
      {ReadResult, %{path: "a", revision: revision, lines: [], next_line: nil, file_bytes: 0}},
      {WriteRequest, %{path: "a", content: "", expected_revision: :missing}},
      {EditRequest, %{path: "a", old_text: "x", new_text: "", expected_revision: revision}},
      {MutationResult,
       %{
         operation_id: "op",
         path: "a",
         previous_revision: :missing,
         revision: revision,
         bytes_written: 0,
         changed: true,
         diff: "",
         diff_truncated: false
       }},
      {ProcessSpec, %{executable: "/bin/sh", mutation: :unknown}},
      {ProcessEvent.Started, %{operation_id: "op"}},
      {ProcessEvent.Output, %{operation_id: "op", sequence: 1, data: ""}},
      {ProcessResult,
       %{
         operation_id: "op",
         termination: :exited,
         exit_code: 0,
         output: "",
         output_bytes: 0,
         truncated: false,
         elapsed_ms: 0
       }},
      {Error,
       %{
         kind: :invalid,
         reason: :invalid_request,
         operation: :read,
         message: "Invalid request",
         outcome: :not_applied
       }}
    ]

    for {module, attrs} <- constructors do
      assert {:error, {:unknown_fields, [:unexpected]}} =
               apply(module, :new, [Map.put(attrs, :unexpected, true)])
    end

    assert {:error, {:attributes, :must_be_keyword_or_map}} =
             ReadRequest.new([{:path, "a"} | :invalid])

    huge_unknown = String.duplicate("sensitive", 10_000)

    assert {:error, {:unknown_fields, [:unknown]}} =
             ReadRequest.new(%{huge_unknown => true, path: "a"})
  end

  test "public struct fields stay intentional and bounded at the facade boundary" do
    assert fields(Handle) == [:access, :backend, :limits, :state, :token]

    assert fields(Error) == [
             :details,
             :kind,
             :message,
             :operation,
             :operation_id,
             :outcome,
             :path,
             :reason
           ]

    assert fields(ReadRequest) == [:line_count, :max_bytes, :path, :start_line]

    assert fields(MutationResult) ==
             [
               :bytes_written,
               :changed,
               :diff,
               :diff_truncated,
               :operation_id,
               :path,
               :previous_revision,
               :revision
             ]

    refute :root in fields(Handle)
    refute :content in fields(Error)
    refute :environment in fields(ProcessSpec)
  end

  defp revision do
    {:ok, revision} = Revision.from_mac(:crypto.hash(:sha256, "workspace-contract-test"))
    revision
  end

  defp access do
    {:ok, access} = Access.new(read: true, write: true, exec: true)
    access
  end

  defp fields(module), do: module.__struct__() |> Map.from_struct() |> Map.keys() |> Enum.sort()
end
