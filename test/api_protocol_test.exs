defmodule Synapse.API.ProtocolTest do
  use ExUnit.Case, async: false

  alias Synapse.API.Command.{Cancel, Ping, Start, Subscribe}
  alias Synapse.API.{Config, Protocol}

  doctest Protocol

  test "decodes exact fixtures for every command" do
    config = config()
    run_id = run_id()

    assert {:ok, {"request-start", %Start{} = start}} =
             Protocol.decode(
               ~S({
                 "version": 1,
                 "type": "run.start",
                 "request_id": "request-start",
                 "payload": {
                   "prompt": "Inspect the project.",
                   "cwd": "/tmp/project",
                   "model": "model-a",
                   "budget": {"max_turns": 10, "max_provider_retries": 1}
                 }
               }),
               config
             )

    assert start.prompt == "Inspect the project."
    assert start.cwd == "/tmp/project"
    assert start.model == "model-a"
    assert start.budget.max_turns == 10
    assert start.budget.max_provider_retries == 1

    assert {:ok, {"request-cancel", %Cancel{run_id: ^run_id}}} =
             Protocol.decode(
               ~s({"version":1,"type":"run.cancel","request_id":"request-cancel","payload":{"run_id":"#{run_id}"}}),
               config
             )

    assert {:ok, {"request-subscribe", %Subscribe{run_id: ^run_id, after_seq: 42}}} =
             Protocol.decode(
               ~s({"version":1,"type":"run.subscribe","request_id":"request-subscribe","payload":{"run_id":"#{run_id}","after_seq":42}}),
               config
             )

    assert {:ok, {"request-ping", %Ping{}}} =
             Protocol.decode(
               ~S({"version":1,"type":"ping","request_id":"request-ping","payload":{}}),
               config
             )
  end

  test "start resolves omitted model and Budget from trusted policy" do
    config = config()

    assert {:ok, {"request-1", %Start{} = start}} =
             decode_start(%{"prompt" => "Inspect", "cwd" => "/tmp/project"}, config)

    assert start.model == config.default_model
    assert start.budget == config.budget

    assert {:error, :invalid_payload, "request-1"} =
             decode_start(
               %{"prompt" => "Inspect", "cwd" => "/tmp/project", "model" => nil},
               config
             )

    assert {:error, :invalid_payload, "request-1"} =
             decode_start(
               %{"prompt" => "Inspect", "cwd" => "/tmp/project", "budget" => nil},
               config
             )
  end

  test "every Budget field may be omitted, lowered, or equal but never widened" do
    config = config()
    fields = Map.from_struct(config.budget)

    Enum.each(fields, fn {field, server_value} ->
      wire_field = Atom.to_string(field)
      omitted = fields |> Map.delete(field) |> stringify_keys()

      assert {:ok, {_, %Start{budget: inherited}}} =
               decode_start(start_payload(%{"budget" => omitted}), config)

      assert Map.fetch!(inherited, field) == server_value

      lower_value = lower_value(field, server_value)

      assert {:ok, {_, %Start{budget: lowered}}} =
               decode_start(start_payload(%{"budget" => %{wire_field => lower_value}}), config)

      assert Map.fetch!(lowered, field) == lower_value

      assert {:ok, {_, %Start{budget: equal}}} =
               decode_start(start_payload(%{"budget" => %{wire_field => server_value}}), config)

      assert Map.fetch!(equal, field) == server_value

      assert {:error, :invalid_payload, "request-1"} =
               decode_start(
                 start_payload(%{"budget" => %{wire_field => server_value + 1}}),
                 config
               )
    end)
  end

  test "rejects malformed JSON and exact-envelope violations with safe correlation" do
    config = config()

    assert {:error, :invalid_json, nil} = Protocol.decode("{", config)
    assert {:error, :invalid_json, nil} = Protocol.decode(<<34, 255, 34>>, config)
    assert {:error, :invalid_envelope, nil} = Protocol.decode("[]", config)

    assert {:error, :invalid_envelope, "request-1"} =
             decode(%{"extra" => true}, config)

    assert {:error, :invalid_envelope, "request-1"} =
             decode(%{"version" => "1"}, config)

    assert {:error, :unsupported_version, "request-1"} =
             decode(%{"version" => 2}, config)

    assert {:error, :unknown_type, "request-1"} =
             decode(%{"type" => "unknown"}, config)

    assert {:error, :invalid_envelope, "request-1"} =
             decode(%{"payload" => []}, config)

    assert {:error, :invalid_request_id, nil} =
             decode(%{"request_id" => "bad\nrequest"}, config)
  end

  test "rejects unknown fields, wrong values, explicit null optionals, and authority injection" do
    config = config()
    run_id = run_id()

    injection_fields = [
      "run_id",
      "capabilities",
      "provider",
      "provider_module",
      "provider_options",
      "runtime_options",
      "callback",
      "callbacks",
      "event_sink",
      "retry_delay",
      "workspace_opener",
      "provider_activity_sink",
      "tool_activity_sink",
      "api_key",
      "credential",
      "credentials",
      "authorization",
      "cookie",
      "token",
      "handle",
      "runtime_run",
      "workspace_handle",
      "supervisor",
      "session_supervisor",
      "instructions",
      "tool_limits",
      "workspace_limits",
      "__struct__"
    ]

    for field <- injection_fields do
      extra = %{field => %{"__struct__" => "Elixir.SYNTHETIC_AUTHORITY_#{field}"}}

      assert {:error, :invalid_payload, "request-1"} =
               decode_start(Map.merge(start_payload(), extra), config)
    end

    for {field, value} <- [
          {"prompt", %{"__struct__" => "Elixir.SecretCallback"}},
          {"model", %{"__struct__" => "Elixir.SecretProvider"}},
          {"budget", %{"__struct__" => "Elixir.Synapse.Runtime.Options"}}
        ] do
      assert {:error, :invalid_payload, "request-1"} =
               decode_start(Map.put(start_payload(), field, value), config)
    end

    invalid_starts = [
      %{"prompt" => "", "cwd" => "/tmp/project"},
      %{"prompt" => "Inspect", "cwd" => "relative"},
      %{"prompt" => "Inspect", "cwd" => "/bad\0path"},
      %{"prompt" => "Inspect", "cwd" => "/tmp/project", "model" => "model-b"},
      %{"prompt" => "Inspect", "cwd" => "/tmp/project", "budget" => %{"unknown" => 1}},
      %{"prompt" => "Inspect", "cwd" => "/tmp/project", "budget" => %{"max_turns" => 1.0}}
    ]

    Enum.each(invalid_starts, fn payload ->
      assert {:error, :invalid_payload, "request-1"} = decode_start(payload, config)
    end)

    assert {:error, :invalid_payload, "request-1"} =
             decode(%{"type" => "ping", "payload" => %{"echo" => "no"}}, config)

    assert {:error, :invalid_payload, "request-1"} =
             decode(
               %{"type" => "run.cancel", "payload" => %{"run_id" => run_id, "extra" => 1}},
               config
             )

    assert {:error, :invalid_payload, "request-1"} =
             decode(
               %{
                 "type" => "run.subscribe",
                 "payload" => %{"run_id" => run_id, "after_seq" => nil}
               },
               config
             )
  end

  test "requires canonical API run IDs and signed-64-bit cursors" do
    config = config()
    run_id = run_id()
    <<prefix::binary-size(25), _last>> = run_id
    noncanonical_alias = prefix <> "B"

    assert {:error, :invalid_payload, "request-1"} =
             decode(
               %{"type" => "run.cancel", "payload" => %{"run_id" => noncanonical_alias}},
               config
             )

    for cursor <- [-1, 1.0, "1"] do
      assert {:error, :invalid_payload, "request-1"} =
               decode(
                 %{
                   "type" => "run.subscribe",
                   "payload" => %{"run_id" => run_id, "after_seq" => cursor}
                 },
                 config
               )
    end

    assert {:error, :invalid_envelope, "request-1"} =
             decode(
               %{
                 "type" => "run.subscribe",
                 "payload" => %{
                   "run_id" => run_id,
                   "after_seq" => 9_223_372_036_854_775_808
                 }
               },
               config
             )

    assert {:ok, {_, %Subscribe{after_seq: 9_223_372_036_854_775_807}}} =
             decode(
               %{
                 "type" => "run.subscribe",
                 "payload" => %{
                   "run_id" => run_id,
                   "after_seq" => 9_223_372_036_854_775_807
                 }
               },
               config
             )

    assert {:ok, {_, %Subscribe{after_seq: nil}}} =
             decode(%{"type" => "run.subscribe", "payload" => %{"run_id" => run_id}}, config)
  end

  test "accepts exact string boundaries and rejects one byte over" do
    config = config()
    request_id = String.duplicate("r", config.max_request_id_bytes)

    assert {:ok, {^request_id, %Ping{}}} = Protocol.decode(ping_message(request_id), config)

    assert {:error, :invalid_request_id, nil} =
             Protocol.decode(ping_message(request_id <> "r"), config)

    prompt = String.duplicate("p", config.max_prompt_bytes)

    assert {:ok, {_, %Start{prompt: ^prompt}}} =
             decode_start(start_payload(%{"prompt" => prompt}), config)

    assert {:error, :invalid_payload, "request-1"} =
             decode_start(start_payload(%{"prompt" => prompt <> "p"}), config)

    cwd = "/" <> String.duplicate("c", 4_095)
    assert {:ok, {_, %Start{cwd: ^cwd}}} = decode_start(start_payload(%{"cwd" => cwd}), config)

    assert {:error, :invalid_payload, "request-1"} =
             decode_start(start_payload(%{"cwd" => cwd <> "c"}), config)
  end

  test "maximum escaped command fields fit the complete incoming envelope" do
    request_id = String.duplicate(~S("), 128)
    prompt = String.duplicate(<<0>>, 262_144)
    model = String.duplicate("\\", 256)
    cwd = "/" <> String.duplicate("\\", 4_095)

    {:ok, config} =
      Config.new(
        enabled: true,
        launch_cwd: "/synthetic/api-protocol-launch",
        default_model: model
      )

    message =
      JSON.encode!(%{
        "version" => 1,
        "type" => "run.start",
        "request_id" => request_id,
        "payload" => %{"prompt" => prompt, "cwd" => cwd, "model" => model}
      })

    assert byte_size(message) <= config.max_incoming_message_bytes

    assert {:ok, {^request_id, %Start{prompt: ^prompt, cwd: ^cwd, model: ^model}}} =
             Protocol.decode(message, config)

    assert {:error, :invalid_payload, "request-1"} =
             decode_start(%{"prompt" => prompt <> <<0>>, "cwd" => cwd, "model" => model}, config)
  end

  test "checks encoded size before decoding" do
    config = config()
    oversized = String.duplicate(" ", config.max_incoming_message_bytes + 1)
    assert {:close, :message_too_big} = Protocol.decode(oversized, config)
  end

  test "bounds depth, object keys, arrays, aggregate nodes, and all integers" do
    {:ok, config} =
      Config.new(
        enabled: true,
        launch_cwd: "/synthetic/api-protocol-launch",
        default_model: "model-a",
        max_json_object_keys: 7,
        max_json_array_elements: 1,
        max_json_nodes: 16
      )

    assert {:error, :invalid_payload, "request-1"} =
             decode(%{"type" => "ping", "payload" => object_with_keys(7)}, config)

    assert {:error, :invalid_envelope, "request-1"} =
             decode(%{"type" => "ping", "payload" => object_with_keys(8)}, config)

    assert {:error, :invalid_payload, "request-1"} =
             decode(%{"type" => "ping", "payload" => %{"items" => [1]}}, config)

    assert {:error, :invalid_envelope, "request-1"} =
             decode(%{"type" => "ping", "payload" => %{"items" => [1, 2]}}, config)

    {:ok, nodes_config} =
      Config.new(
        enabled: true,
        launch_cwd: "/synthetic/api-protocol-launch",
        default_model: "model-a",
        max_json_nodes: 16
      )

    assert {:error, :invalid_payload, "request-1"} =
             decode(
               %{"type" => "ping", "payload" => %{"items" => List.duplicate(1, 10)}},
               nodes_config
             )

    assert {:error, :invalid_envelope, "request-1"} =
             decode(
               %{"type" => "ping", "payload" => %{"items" => List.duplicate(1, 11)}},
               nodes_config
             )

    assert {:error, :invalid_envelope, "request-1"} =
             decode(
               %{"type" => "ping", "payload" => %{"integer" => 9_223_372_036_854_775_808}},
               config
             )

    assert {:error, :invalid_payload, "request-1"} =
             decode(
               %{"type" => "ping", "payload" => %{"integer" => -9_223_372_036_854_775_808}},
               config
             )

    assert {:error, :invalid_envelope, "request-1"} =
             decode(
               %{"type" => "ping", "payload" => %{"integer" => -9_223_372_036_854_775_809}},
               config
             )

    default = config()

    assert {:error, :invalid_payload, "request-1"} =
             decode(%{"type" => "ping", "payload" => nested_object(14)}, default)

    assert {:error, :invalid_envelope, "request-1"} =
             decode(%{"type" => "ping", "payload" => nested_object(15)}, default)
  end

  test "documents selected duplicate-key behavior" do
    config = config()

    message =
      ~S({"version":1,"type":"ping","type":"unknown","request_id":"request-1","payload":{}})

    assert {:ok, {"request-1", %Ping{}}} = Protocol.decode(message, config)
  end

  test "many unique external strings do not create atoms" do
    config = config()
    assert {:ok, _command} = Protocol.decode(ping_message("warm-up"), config)
    before = :erlang.system_info(:atom_count)

    for ordinal <- 1..1_000 do
      assert {:ok, _command} = Protocol.decode(ping_message("external-#{ordinal}"), config)
    end

    assert :erlang.system_info(:atom_count) <= before + 1
  end

  test "deterministic bounded JSON and malformed mutation corpora never crash or create atoms" do
    config = config()
    warm = seeded_json_corpus(64, "phase8-warm")
    corpus = seeded_json_corpus(512, "phase8-never-warmed")
    malformed = malformed_corpus(256)

    Enum.each(warm, fn value ->
      value |> JSON.encode!() |> Protocol.decode(config) |> assert_decode_result()
    end)

    Enum.each(Enum.take(malformed, 8), fn message ->
      message |> Protocol.decode(config) |> assert_decode_result()
    end)

    before = :erlang.system_info(:atom_count)

    Enum.each(corpus, fn value ->
      value |> JSON.encode!() |> Protocol.decode(config) |> assert_decode_result()
    end)

    Enum.each(malformed, fn message ->
      message |> Protocol.decode(config) |> assert_decode_result()
    end)

    assert :erlang.system_info(:atom_count) <= before + 1
  end

  test "deep size-bounded JSON terminates normally without affecting later decoding" do
    config = config()

    Enum.each([17, 256, 4_096], fn depth ->
      message = String.duplicate("[", depth) <> "0" <> String.duplicate("]", depth)
      parent = self()

      {pid, monitor} =
        spawn_monitor(fn ->
          send(parent, {:deep_decode, self(), Protocol.decode(message, config)})
        end)

      assert_receive {:deep_decode, ^pid, result}, 5_000
      assert_decode_result(result)
      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 5_000
    end)

    assert {:ok, {"still-alive", %Ping{}}} =
             Protocol.decode(ping_message("still-alive"), config)
  end

  defp config do
    {:ok, config} =
      Config.new(
        enabled: true,
        launch_cwd: "/synthetic/api-protocol-launch",
        default_model: "model-a"
      )

    config
  end

  defp decode(overrides, config) do
    envelope = %{
      "version" => 1,
      "type" => "ping",
      "request_id" => "request-1",
      "payload" => %{}
    }

    envelope |> Map.merge(overrides) |> JSON.encode!() |> Protocol.decode(config)
  end

  defp decode_start(payload, config),
    do: decode(%{"type" => "run.start", "payload" => payload}, config)

  defp start_payload(extra \\ %{}),
    do: Map.merge(%{"prompt" => "Inspect", "cwd" => "/tmp/project"}, extra)

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)

  defp lower_value(:max_provider_retries, value), do: max(value - 1, 0)
  defp lower_value(_field, value), do: max(value - 1, 1)

  defp object_with_keys(count),
    do: Map.new(1..count, fn ordinal -> {"key-#{ordinal}", ordinal} end)

  defp nested_object(0), do: "leaf"
  defp nested_object(depth), do: %{"next" => nested_object(depth - 1)}

  defp seeded_json_corpus(count, prefix) do
    state = :rand.seed_s(:exsss, {1_337, 4_242, 9_001})

    1..count
    |> Enum.map_reduce(state, fn ordinal, state ->
      random_json(state, 0, prefix, ordinal)
    end)
    |> elem(0)
  end

  defp random_json(state, depth, prefix, ordinal) do
    {choice, state} = :rand.uniform_s(if(depth >= 6, do: 5, else: 8), state)

    case choice do
      1 ->
        {nil, state}

      2 ->
        {rem(ordinal, 2) == 0, state}

      3 ->
        {ordinal - 256, state}

      4 ->
        {"#{prefix}-value-#{ordinal}-#{String.duplicate("\"\\", rem(ordinal, 16))}", state}

      5 ->
        {9_223_372_036_854_775_807 - ordinal, state}

      6 ->
        random_json_list(state, depth, prefix, ordinal)

      7 ->
        random_json_map(state, depth, prefix, ordinal)

      8 ->
        {%{
           "version" => 1,
           "type" => "ping",
           "request_id" => "#{prefix}-request-#{ordinal}",
           "payload" => %{"#{prefix}-payload-key-#{ordinal}" => ordinal}
         }, state}
    end
  end

  defp random_json_list(state, depth, prefix, ordinal) do
    {count, state} = :rand.uniform_s(5, state)

    Enum.map_reduce(1..count, state, fn index, state ->
      random_json(state, depth + 1, prefix, ordinal * 10 + index)
    end)
  end

  defp random_json_map(state, depth, prefix, ordinal) do
    {count, state} = :rand.uniform_s(5, state)

    {entries, state} =
      Enum.map_reduce(1..count, state, fn index, state ->
        {value, state} = random_json(state, depth + 1, prefix, ordinal * 10 + index)
        {{"#{prefix}-key-#{ordinal}-#{index}", value}, state}
      end)

    {Map.new(entries), state}
  end

  defp malformed_corpus(count) do
    bases = [
      "{",
      "[",
      ~S({"broken":"\u"}),
      ~S({"broken":"\uD800"}),
      ~S({"number":01}),
      ~S({"number":1e}),
      ~S({"trailing":true} garbage),
      <<34, 255, 34>>
    ]

    Enum.map(1..count, fn ordinal ->
      Enum.at(bases, rem(ordinal, length(bases))) <> String.duplicate(" ", rem(ordinal, 64))
    end)
  end

  defp assert_decode_result({:ok, {_request_id, command}})
       when is_struct(command, Start) or is_struct(command, Cancel) or
              is_struct(command, Subscribe) or is_struct(command, Ping),
       do: :ok

  defp assert_decode_result({:error, code, request_id})
       when code in [
              :invalid_json,
              :invalid_envelope,
              :unsupported_version,
              :unknown_type,
              :invalid_request_id,
              :invalid_payload,
              :internal_error
            ] and (is_binary(request_id) or is_nil(request_id)),
       do: :ok

  defp assert_decode_result({:close, :message_too_big}), do: :ok
  defp assert_decode_result(other), do: flunk("unexpected decode result: #{inspect(other)}")

  defp ping_message(request_id),
    do:
      JSON.encode!(%{
        "version" => 1,
        "type" => "ping",
        "request_id" => request_id,
        "payload" => %{}
      })

  defp run_id, do: "run_" <> Base.url_encode64(<<0::128>>, padding: false)
end
