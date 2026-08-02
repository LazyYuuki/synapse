defmodule Synapse.Tool.ContractsTest do
  use ExUnit.Case, async: true

  alias Synapse.Provider.OutputItem.FunctionCall
  alias Synapse.Tool

  alias Synapse.Tool.{Call, CapabilitySet, Context, Limits, Result, Spec, Validation}

  alias Synapse.Workspace.{Access, Fake, Handle}
  alias Synapse.Workspace.Limits, as: WorkspaceLimits

  doctest Call
  doctest Result
  doctest Spec

  defmodule ExampleTool do
    @behaviour Tool

    @impl true
    def specification, do: Synapse.Tool.ContractsTest.valid_spec()

    @impl true
    def prepare(_call, _limits), do: {:error, :invalid_arguments}

    @impl true
    def present(call, _outcome, _limits) do
      {:ok, result} =
        Result.ok(
          call_id: call.call_id,
          content: ~s({"status":"ok","tool":"example"})
        )

      result
    end
  end

  describe "Call" do
    test "constructs bounded generic string-keyed calls and rejects unknown fields" do
      assert {:ok, call} =
               Call.new(
                 call_id: "call-1",
                 name: "unknown_but_valid",
                 arguments: %{"nested" => [%{"value" => 1}, nil, true]}
               )

      assert MapSet.new(Map.keys(Map.from_struct(call))) ==
               MapSet.new([:arguments, :call_id, :name])

      assert call.arguments["nested"] |> hd() |> Map.has_key?("value")

      assert {:error, {:unknown_fields, [:item_id]}} =
               Call.new(call_id: "call-1", name: "read", arguments: %{}, item_id: "item-1")

      assert {:error, {:attributes, :must_be_keyword_or_map}} =
               Call.new([{:call_id, "call-1"} | :bad])
    end

    test "validates identifier bytes and controls without normalizing accepted values" do
      assert {:ok, call} =
               Call.new(call_id: " call-with-spaces ", name: "read", arguments: %{})

      assert call.call_id == " call-with-spaces "

      for invalid <- ["", "   ", "bad\nname", "bad\0name", <<255>>] do
        assert {:error, {:call_id, :must_be_bounded_non_empty_utf8_identifier}} =
                 Call.new(call_id: invalid, name: "read", arguments: %{})
      end

      assert {:ok, _call} =
               Call.new(
                 call_id: String.duplicate("c", 512),
                 name: String.duplicate("n", 64),
                 arguments: %{}
               )

      assert {:error, {:call_id, :must_be_bounded_non_empty_utf8_identifier}} =
               Call.new(call_id: String.duplicate("c", 513), name: "read", arguments: %{})

      assert {:error, {:name, :must_be_bounded_non_empty_utf8_identifier}} =
               Call.new(call_id: "call", name: String.duplicate("n", 65), arguments: %{})
    end

    test "counts actual encoded argument bytes including escaping" do
      arguments = %{"a" => "\"\\\n"}
      encoded_bytes = arguments |> Elixir.JSON.encode!() |> byte_size()
      {:ok, exact} = Limits.new(max_argument_json_bytes: encoded_bytes)
      {:ok, short} = Limits.new(max_argument_json_bytes: encoded_bytes - 1)

      assert {:ok, _call} =
               Call.new(%{call_id: "call", name: "read", arguments: arguments}, exact)

      assert {:error, {:arguments, :must_be_bounded_string_keyed_json_object}} =
               Call.new(%{call_id: "call", name: "read", arguments: arguments}, short)
    end

    test "bounds aggregate entries and nested container depth" do
      sixteen = Map.new(1..16, &{"k#{&1}", &1})
      seventeen = Map.put(sixteen, "extra", 17)

      assert {:ok, _call} = Call.new(call_id: "call", name: "read", arguments: sixteen)

      assert {:error, {:arguments, :must_be_bounded_string_keyed_json_object}} =
               Call.new(call_id: "call", name: "read", arguments: seventeen)

      {:ok, depth_one} = Limits.new(max_argument_depth: 1)

      assert {:ok, _call} =
               Call.new(
                 %{call_id: "call", name: "read", arguments: %{"a" => %{"b" => 1}}},
                 depth_one
               )

      assert {:error, {:arguments, :must_be_bounded_string_keyed_json_object}} =
               Call.new(
                 %{call_id: "call", name: "read", arguments: %{"a" => %{"b" => %{"c" => 1}}}},
                 depth_one
               )
    end

    test "rejects non-JSON, malformed, unbounded, and forged nested values" do
      invalid_values = [
        %{atom: "key"},
        %{"invalid" => <<255>>},
        %{"improper" => [1 | 2]},
        %{"tuple" => {:not, :json}},
        %{"pid" => self()},
        %{"reference" => make_ref()},
        %{"function" => fn -> :ok end},
        %{"struct" => Limits.default()},
        %{"integer" => 9_223_372_036_854_775_808}
      ]

      Enum.each(invalid_values, fn arguments ->
        assert {:error, {:arguments, :must_be_bounded_string_keyed_json_object}} =
                 Call.new(call_id: "call", name: "read", arguments: arguments)
      end)

      refute inspect(%Call{
               call_id: "synthetic-secret",
               name: "read",
               arguments: %{"token" => "secret"}
             }) =~
               "synthetic-secret"

      refute inspect(%Call{call_id: "call", name: "read", arguments: %{"token" => "secret"}}) =~
               "token"
    end

    test "copies complete Provider calls and discards output item identity" do
      provider_call = %FunctionCall{
        id: "item-1",
        call_id: "call-1",
        name: "read",
        arguments: %{"path" => "mix.exs"}
      }

      assert {:ok, call} = Call.from_provider(provider_call)
      assert call.call_id == provider_call.call_id
      assert call.name == provider_call.name
      assert call.arguments == provider_call.arguments
      refute Map.has_key?(Map.from_struct(call), :id)

      assert {:error, {:function_call, :must_be_complete_provider_function_call}} =
               Call.from_provider(%FunctionCall{provider_call | id: ""})

      assert {:error, {:function_call, :must_be_complete_provider_function_call}} =
               Call.from_provider(%{})
    end
  end

  describe "Result" do
    test "constructs all statuses with direct and status-specific constructors" do
      assert {:ok, %Result{status: :ok}} =
               Result.new(
                 call_id: "call-ok",
                 status: :ok,
                 content: ~s({"status":"ok","tool":"read"}),
                 metadata: %{"tool" => "read", "outcome" => "completed"}
               )

      assert {:ok, %Result{status: :error}} =
               Result.error(
                 call_id: "call-error",
                 content:
                   ~s({"status":"error","error":{"reason":"not_found","outcome":"not_applied"}})
               )

      assert {:ok, %Result{status: :ambiguous}} =
               Result.ambiguous(
                 call_id: "call-ambiguous",
                 content:
                   ~s({"status":"ambiguous","error":{"reason":"unknown","outcome":"unknown"}})
               )

      assert {:error, {:unknown_fields, [:status]}} =
               Result.ok(
                 call_id: "call",
                 status: :ok,
                 content: ~s({"status":"ok"})
               )
    end

    test "requires valid bounded JSON object content with matching status and outcome" do
      invalid_content = ["", "[]", "true", "not-json", <<255>>, "{\"status\":\"ok\"} trailing"]

      Enum.each(invalid_content, fn content ->
        assert {:error, {:content, :must_be_bounded_utf8_json_object}} =
                 Result.ok(call_id: "call", content: content)
      end)

      assert {:error, {:content, :status_must_match_result}} =
               Result.error(call_id: "call", content: ~s({"status":"ok"}))

      assert {:error, {:content, :outcome_must_match_status}} =
               Result.ambiguous(call_id: "call", content: ~s({"status":"ambiguous"}))

      assert {:error, {:content, :outcome_must_match_status}} =
               Result.ok(
                 call_id: "call",
                 content: ~s({"status":"ok","outcome":"unknown"})
               )

      assert {:error, {:content, :outcome_must_match_status}} =
               Result.error(
                 call_id: "call",
                 content: ~s({"status":"error","outcome":"unknown"})
               )

      assert {:error, {:content, :must_be_bounded_utf8_json_object}} =
               Result.ok(call_id: "call", content: "{\"status\":\"ok\",\"value\":\"\x7F\"}")

      for duplicate <- [
            ~s({"status":"ok","status":"error"}),
            ~s({"status":"ok","\u0073tatus":"error"}),
            ~s({"status":"ok","outcome":"completed","outcome":"unknown"}),
            ~s({"status":"error","error":{"outcome":"not_applied","outcome":"unknown"}})
          ] do
        assert {:error, {:content, :must_be_bounded_utf8_json_object}} =
                 Result.ok(call_id: "call", content: duplicate)
      end

      for content <- [
            ~s({"status":"ok","outcome":null}),
            ~s({"status":"error","outcome":null}),
            ~s({"status":"ambiguous","outcome":null}),
            ~s({"status":"error","error":{"outcome":null}})
          ] do
        assert {:error, {:content, :outcome_must_match_status}} =
                 Result.new(call_id: "call", status: status_in(content), content: content)
      end

      assert {:error, {:content, :outcome_must_match_status}} =
               Result.ok(
                 call_id: "call",
                 content: ~s({"status":"ok"}),
                 metadata: %{"outcome" => nil}
               )
    end

    test "counts final content and metadata bytes and bounds metadata shape" do
      empty_content = Elixir.JSON.encode!(%{"status" => "ok", "padding" => ""})
      padding = String.duplicate("x", 256 - byte_size(empty_content))
      content = Elixir.JSON.encode!(%{"status" => "ok", "padding" => padding})
      oversized_content = Elixir.JSON.encode!(%{"status" => "ok", "padding" => padding <> "x"})
      {:ok, exact_content} = Limits.new(max_result_content_bytes: 256)

      assert byte_size(content) == 256
      assert byte_size(oversized_content) == 257

      assert {:ok, _result} = Result.ok([call_id: "call", content: content], exact_content)

      assert {:error, {:content, :must_be_bounded_utf8_json_object}} =
               Result.ok([call_id: "call", content: oversized_content], exact_content)

      metadata = %{"a" => "\"\\\n"}
      metadata_bytes = metadata |> Elixir.JSON.encode!() |> byte_size()
      {:ok, exact_metadata} = Limits.new(max_result_metadata_json_bytes: metadata_bytes)
      {:ok, short_metadata} = Limits.new(max_result_metadata_json_bytes: metadata_bytes - 1)

      assert {:ok, _result} =
               Result.ok([call_id: "call", content: content, metadata: metadata], exact_metadata)

      assert {:error, {:metadata, :must_be_bounded_safe_json_object}} =
               Result.ok([call_id: "call", content: content, metadata: metadata], short_metadata)

      unsafe_metadata = [
        %{"authorization" => "value"},
        %{"safe" => %{"process_output" => "value"}},
        %{"command" => "value"},
        %{"absolute-path" => "value"},
        %{atom: "value"}
      ]

      Enum.each(unsafe_metadata, fn metadata ->
        assert {:error, {:metadata, :must_be_bounded_safe_json_object}} =
                 Result.ok(call_id: "call", content: content, metadata: metadata)
      end)

      thirty_two = Map.new(1..32, &{"safe_#{&1}", &1})
      thirty_three = Map.put(thirty_two, "safe_extra", 33)

      assert {:ok, _result} =
               Result.ok(call_id: "call", content: content, metadata: thirty_two)

      assert {:error, {:metadata, :must_be_bounded_safe_json_object}} =
               Result.ok(call_id: "call", content: content, metadata: thirty_three)

      assert {:ok, _result} =
               Result.ok(call_id: "call", content: content, metadata: nested_object(4))

      assert {:error, {:metadata, :must_be_bounded_safe_json_object}} =
               Result.ok(call_id: "call", content: content, metadata: nested_object(5))
    end

    test "bounds Result call identity independently from Workspace operation identity" do
      content = ~s({"status":"ok"})

      assert {:ok, _result} =
               Result.ok(call_id: String.duplicate("c", 512), content: content)

      assert {:error, {:call_id, :must_be_bounded_non_empty_utf8_identifier}} =
               Result.ok(call_id: String.duplicate("c", 513), content: content)

      assert {:error, {:call_id, :must_be_bounded_non_empty_utf8_identifier}} =
               Result.ok(call_id: "bad\ncall", content: content)
    end

    test "redacts pairing, content, and metadata under ordinary inspection" do
      result = %Result{
        call_id: "synthetic-call-secret",
        status: :ok,
        content: ~s({"status":"ok","content":"synthetic-content-secret"}),
        metadata: %{"safe" => "synthetic-metadata-secret"}
      }

      inspected = inspect(result)
      assert inspected =~ "status=:ok"
      refute inspected =~ "synthetic-call-secret"
      refute inspected =~ "synthetic-content-secret"
      refute inspected =~ "synthetic-metadata-secret"
    end
  end

  describe "Spec and Tool behavior" do
    test "validates strict schemas and every fixed capability/effect combination" do
      for capability <- [:fs_read, :fs_write, :process_exec],
          effect <- [:read_only, :mutation, :unknown] do
        attrs = valid_spec_attrs() |> Map.put(:capability, capability) |> Map.put(:effect, effect)
        assert {:ok, %Spec{capability: ^capability, effect: ^effect}} = Spec.new(attrs)
      end

      spec = valid_spec()

      assert MapSet.new(Map.keys(Map.from_struct(spec))) ==
               MapSet.new([:capability, :description, :effect, :name, :parameters])

      refute Map.has_key?(Map.from_struct(spec), :module)
      refute Map.has_key?(Map.from_struct(spec), :strict)
      refute Map.has_key?(Map.from_struct(spec), :type)

      assert ExampleTool.specification() == spec

      assert Tool.behaviour_info(:callbacks) |> Enum.sort() ==
               [prepare: 2, present: 3, specification: 0]
    end

    test "rejects malformed schema envelopes, properties, required names, and policy" do
      attrs = valid_spec_attrs()

      invalid_parameters = [
        Map.delete(attrs.parameters, "required"),
        Map.put(attrs.parameters, "extra", true),
        Map.put(attrs.parameters, "type", "string"),
        Map.put(attrs.parameters, "additionalProperties", true),
        put_in(attrs.parameters["required"], []),
        put_in(attrs.parameters["required"], ["path", "path"]),
        put_in(attrs.parameters["properties"]["path"]["type"], ["null", "integer"]),
        put_in(attrs.parameters["properties"]["path"]["minimum"], 0),
        put_in(attrs.parameters["properties"]["path"]["minimum"], nil),
        put_in(attrs.parameters["properties"]["path"]["unknown"], true),
        put_in(attrs.parameters["properties"]["path"]["description"], "")
      ]

      Enum.each(invalid_parameters, fn parameters ->
        assert {:error, {:parameters, :must_be_complete_strict_flat_object_schema}} =
                 Spec.new(%{attrs | parameters: parameters})
      end)

      assert {:error, {:capability, :must_be_known}} = Spec.new(%{attrs | capability: "fs_read"})
      assert {:error, {:effect, :must_be_known}} = Spec.new(%{attrs | effect: :parallel})

      assert {:error, {:name, :must_be_bounded_non_empty_utf8_identifier}} =
               Spec.new(%{attrs | name: "bad\nname"})

      assert {:error, {:description, :must_be_non_empty_utf8_string}} =
               Spec.new(%{attrs | description: " "})

      null_integer_bound =
        put_in(attrs.parameters["properties"]["path"], %{
          "type" => "integer",
          "description" => "Bounded integer.",
          "minimum" => nil
        })

      assert {:error, {:parameters, :must_be_complete_strict_flat_object_schema}} =
               Spec.new(%{attrs | parameters: null_integer_bound})

      integer_parameters =
        put_in(attrs.parameters["properties"]["path"], %{
          "type" => "integer",
          "description" => "Bounded integer.",
          "minimum" => 10,
          "maximum" => 1
        })

      assert {:error, {:parameters, :must_be_complete_strict_flat_object_schema}} =
               Spec.new(%{attrs | parameters: integer_parameters})

      huge_properties =
        Map.new(1..20_000, &{"property_#{&1}", %{"type" => "string", "description" => "value"}})

      assert {:error, {:parameters, :must_be_complete_strict_flat_object_schema}} =
               Spec.new(%{
                 attrs
                 | parameters: %{attrs.parameters | "properties" => huge_properties}
               })
    end

    test "counts the complete projected schema and redacts parameters" do
      attrs = valid_spec_attrs()

      projected = %{
        "type" => "function",
        "name" => attrs.name,
        "description" => attrs.description,
        "parameters" => attrs.parameters,
        "strict" => true
      }

      bytes = projected |> Elixir.JSON.encode!() |> byte_size()
      {:ok, exact} = Limits.new(max_schema_bytes_per_tool: bytes)
      {:ok, short} = Limits.new(max_schema_bytes_per_tool: bytes - 1)

      assert {:ok, spec} = Spec.new(attrs, exact)
      assert {:error, {:specification, :must_fit_schema_byte_limit}} = Spec.new(attrs, short)

      inspected = inspect(spec)
      assert inspected =~ ~s(name="read")
      assert inspected =~ "capability=:fs_read"
      refute inspected =~ "Relative path"
    end

    test "schema validity is independent from caller-lowered argument depth" do
      {:ok, limits} = Limits.new(max_argument_depth: 1)
      assert {:ok, %Spec{}} = Spec.new(valid_spec_attrs(), limits)
    end
  end

  describe "exact bounded JSON accounting" do
    test "matches the standard encoder for representative bounded values" do
      values = [
        %{},
        [],
        %{"empty" => []},
        %{"quote\"slash\\" => "\n\t\r\b\f\0"},
        %{"unicode" => "hello 😀"},
        %{"nested" => [%{"integer" => -123}, true, false, nil, 1.25]}
      ]

      Enum.each(values, fn value ->
        expected = value |> Elixir.JSON.encode!() |> byte_size()

        assert {:ok, ^expected} = Validation.bounded_json_bytes(value, expected, 100, 10)

        if expected > 1 do
          assert :error = Validation.bounded_json_bytes(value, expected - 1, 100, 10)
        end
      end)
    end
  end

  describe "CapabilitySet and Context" do
    test "CapabilitySet requires exactly three trusted booleans" do
      for read <- [false, true], write <- [false, true], exec <- [false, true] do
        assert {:ok, capabilities} =
                 CapabilitySet.new(fs_read: read, fs_write: write, process_exec: exec)

        assert CapabilitySet.valid?(capabilities)
      end

      assert {:error, {:fs_read, :must_be_boolean}} =
               CapabilitySet.new(fs_write: false, process_exec: false)

      assert {:error, {:unknown_fields, [:shell]}} =
               CapabilitySet.new(
                 fs_read: true,
                 fs_write: false,
                 process_exec: false,
                 shell: true
               )

      refute CapabilitySet.valid?(%CapabilitySet{
               fs_read: :yes,
               fs_write: false,
               process_exec: false
             })
    end

    test "Context revalidates trusted nested contracts and lifetime fields" do
      handle = fake_handle()
      %CapabilitySet{} = capabilities = capabilities()
      %Limits{} = limits = Limits.default()
      cancel_ref = make_ref()
      sink = fn _operation_context -> :ok end

      assert {:ok, context} =
               Context.new(
                 workspace: handle,
                 capabilities: capabilities,
                 operation_id: "tool-operation",
                 cancel_ref: cancel_ref,
                 deadline: 123,
                 activity_sink: sink,
                 limits: limits
               )

      assert context.workspace == handle
      assert context.cancel_ref == cancel_ref
      assert context.deadline == 123
      assert context.activity_sink == sink

      assert {:ok, infinite} =
               Context.new(
                 workspace: handle,
                 capabilities: capabilities,
                 operation_id: "tool-operation",
                 limits: limits
               )

      assert infinite.deadline == :infinity

      assert {:error, {:capabilities, :must_be_tool_capability_set}} =
               Context.new(
                 workspace: handle,
                 capabilities: %CapabilitySet{capabilities | fs_read: :yes},
                 operation_id: "tool-operation",
                 limits: limits
               )

      assert {:error, {:limits, :must_be_tool_limits}} =
               Context.new(
                 workspace: handle,
                 capabilities: capabilities,
                 operation_id: "tool-operation",
                 limits: %Limits{limits | max_path_bytes: 0}
               )
    end

    test "Context rejects malformed Handles and Tool limits above Workspace ceilings" do
      handle = fake_handle()
      capabilities = capabilities()
      %WorkspaceLimits{} = handle_limits = handle.limits

      for malformed <- [
            %Handle{handle | backend: "fake"},
            %Handle{handle | state: :state},
            %Handle{handle | token: nil},
            %Handle{handle | limits: %WorkspaceLimits{handle_limits | max_path_bytes: 0}},
            %Handle{handle | access: %Access{read: :yes, write: false, exec: false}}
          ] do
        assert {:error, {:workspace, :must_be_workspace_handle}} =
                 Context.new(
                   workspace: malformed,
                   capabilities: capabilities,
                   operation_id: "tool-operation",
                   limits: Limits.default()
                 )
      end

      {:ok, workspace_limits} = WorkspaceLimits.new(max_path_bytes: 100)
      {:ok, constrained} = Fake.open([], limits: workspace_limits)
      on_exit(fn -> Synapse.Workspace.close(constrained) end)

      assert {:error, {:limits, :must_fit_workspace_limits}} =
               Context.new(
                 workspace: constrained,
                 capabilities: capabilities,
                 operation_id: "tool-operation",
                 limits: Limits.default()
               )

      {:ok, lowered} = Limits.new(max_path_bytes: 100)

      assert {:ok, _context} =
               Context.new(
                 workspace: constrained,
                 capabilities: capabilities,
                 operation_id: "tool-operation",
                 limits: lowered
               )
    end

    test "Context bounds operation identity, deadline, sink, and inspection" do
      handle = fake_handle()
      capabilities = capabilities()
      limits = Limits.default()

      assert {:ok, _context} = context(handle, capabilities, String.duplicate("o", 256), limits)

      for invalid <- [String.duplicate("o", 257), "bad\noperation", <<255>>] do
        assert {:error, {:operation_id, :must_be_bounded_non_empty_utf8_identifier}} =
                 context(handle, capabilities, invalid, limits)
      end

      assert {:error, {:cancel_ref, :must_be_reference_or_nil}} =
               context(handle, capabilities, "operation", limits, cancel_ref: "ref")

      assert {:error, {:deadline, :must_be_monotonic_time_or_infinity}} =
               context(handle, capabilities, "operation", limits,
                 deadline: 9_223_372_036_854_775_808
               )

      assert {:error, {:activity_sink, :must_be_arity_one_function_or_nil}} =
               context(handle, capabilities, "operation", limits, activity_sink: fn -> :ok end)

      {:ok, valid} = context(handle, capabilities, "synthetic-operation-secret", limits)
      assert inspect(valid) == "#Synapse.Tool.Context<redacted>"
      refute inspect(valid) =~ "synthetic-operation-secret"
    end

    test "Context capability construction does not pretend to authenticate Handle access" do
      {:ok, no_access} = Access.new(read: false, write: false, exec: false)
      {:ok, handle} = Fake.open([], access: no_access)
      on_exit(fn -> Synapse.Workspace.close(handle) end)

      assert {:ok, _context} =
               Context.new(
                 workspace: handle,
                 capabilities: capabilities(),
                 operation_id: "operation",
                 limits: Limits.default()
               )

      forged = %Handle{
        backend: :untrusted_but_structural,
        state: make_ref(),
        token: make_ref(),
        limits: WorkspaceLimits.default(),
        access: no_access
      }

      assert {:ok, _context} =
               Context.new(
                 workspace: forged,
                 capabilities: capabilities(),
                 operation_id: "operation",
                 limits: Limits.default()
               )
    end
  end

  def valid_spec do
    {:ok, spec} = Spec.new(valid_spec_attrs())
    spec
  end

  defp valid_spec_attrs do
    %{
      name: "read",
      description: "Read one bounded project file.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Relative path."}
        },
        "required" => ["path"],
        "additionalProperties" => false
      },
      capability: :fs_read,
      effect: :read_only
    }
  end

  defp capabilities do
    {:ok, capabilities} =
      CapabilitySet.new(fs_read: true, fs_write: true, process_exec: true)

    capabilities
  end

  defp fake_handle do
    {:ok, handle} = Fake.open([])
    on_exit(fn -> Synapse.Workspace.close(handle) end)
    handle
  end

  defp context(handle, capabilities, operation_id, limits, options \\ []) do
    attrs =
      options
      |> Keyword.put(:workspace, handle)
      |> Keyword.put(:capabilities, capabilities)
      |> Keyword.put(:operation_id, operation_id)
      |> Keyword.put(:limits, limits)

    Context.new(attrs)
  end

  defp nested_object(0), do: %{}
  defp nested_object(depth), do: %{"safe" => nested_object(depth - 1)}

  defp status_in(content) do
    {:ok, decoded} = Elixir.JSON.decode(content)

    case decoded["status"] do
      "ok" -> :ok
      "error" -> :error
      "ambiguous" -> :ambiguous
    end
  end
end
