defmodule Synapse.Provider.SSEDecoderTest do
  use ExUnit.Case, async: true

  alias Synapse.Provider.{SSEDecoder, SSEEvent}
  alias Synapse.Provider.SSEDecoder.Error

  doctest SSEDecoder

  test "parses one complete LF event" do
    assert [%SSEEvent{event: "response.created", data: ~s({"id":"response-1"})}] =
             decode(["event: response.created\ndata: {\"id\":\"response-1\"}\n\n"])
  end

  test "parses the same fixture split at every byte boundary" do
    fixture = "event: response.output_text.delta\ndata: {\"delta\":\"hello\"}\n\n"

    for offset <- 0..byte_size(fixture) do
      <<left::binary-size(^offset), right::binary>> = fixture

      assert [%SSEEvent{event: "response.output_text.delta", data: ~s({"delta":"hello"})}] =
               decode([left, right])
    end
  end

  test "parses a fixture fed one byte at a time" do
    fixture = "event: message\ndata: one byte at a time\n\n"
    chunks = for <<byte <- fixture>>, do: <<byte>>

    assert [%SSEEvent{event: "message", data: "one byte at a time"}] = decode(chunks)
  end

  test "supports LF and CRLF line endings" do
    assert [%SSEEvent{event: "message", data: "hello"}] =
             decode(["event: message\ndata: hello\n\n"])

    assert [%SSEEvent{event: "message", data: "hello"}] =
             decode(["event: message\r\ndata: hello\r\n\r\n"])
  end

  test "parses multiple events from one chunk in wire order" do
    chunk = "event: first\ndata: 1\n\nevent: second\ndata: 2\n\n"

    assert [
             %SSEEvent{event: "first", data: "1"},
             %SSEEvent{event: "second", data: "2"}
           ] = decode([chunk])
  end

  test "joins multiple data lines and preserves blank data" do
    fixture = "data: first\ndata:\ndata: third\n\n"

    assert [%SSEEvent{event: nil, data: "first\n\nthird"}] = decode([fixture])
    assert [%SSEEvent{data: ""}] = decode(["data:\n\n"])
  end

  test "parses id and retry while preserving unknown string fields" do
    fixture =
      "id: event-1\nretry: 2500\nx-extension: alpha:beta\nx-extension: second\ndata: ok\n\n"

    assert [
             %SSEEvent{
               event: nil,
               data: "ok",
               id: "event-1",
               retry: 2_500,
               unknown_fields: [
                 {"x-extension", "alpha:beta"},
                 {"x-extension", "second"}
               ]
             }
           ] = decode([fixture])
  end

  test "ignores comments as content but records completed-line activity" do
    decoder = SSEDecoder.new()

    assert {:ok, decoder, []} = SSEDecoder.feed(decoder, ": heartbeat\n")
    assert decoder.activity_count == 1

    assert {:ok, decoder, [event]} = SSEDecoder.feed(decoder, "data: ready\n\n")
    assert event.data == "ready"
    assert decoder.activity_count == 2
  end

  test "retains incomplete lines as fragment lists without changing their bytes" do
    decoder = SSEDecoder.new()

    assert {:ok, decoder, []} = SSEDecoder.feed(decoder, "event: res")
    assert decoder.line_bytes == 10
    assert decoder.event == nil

    assert {:ok, decoder, []} = SSEDecoder.feed(decoder, "ponse.created\n")
    assert decoder.line_bytes == 0
    assert decoder.event == "response.created"
    assert decoder.event_pending

    assert {:ok, decoder, []} = SSEDecoder.feed(decoder, "data: {")
    assert decoder.line_bytes == 7

    assert {:ok, decoder, [%SSEEvent{data: "{}"}]} = SSEDecoder.feed(decoder, "}\n\n")
    refute decoder.event_pending
  end

  test "preserves UTF-8 bytes split at every boundary" do
    fixture = "event: text\ndata: こんにちは 🌊\n\n"

    for offset <- 0..byte_size(fixture) do
      <<left::binary-size(^offset), right::binary>> = fixture
      assert [%SSEEvent{data: "こんにちは 🌊"}] = decode([left, right])
    end
  end

  test "rejects a line larger than its configured limit" do
    decoder = SSEDecoder.new(max_line_bytes: 8)

    assert {:error, %Error{reason: :line_too_large, limit: 8, actual: 9}} =
             SSEDecoder.feed(decoder, "data: 123")
  end

  test "rejects accumulated event fields larger than their configured limit" do
    decoder = SSEDecoder.new(max_event_data_bytes: 10)

    assert {:ok, decoder, []} = SSEDecoder.feed(decoder, "data: one\n")

    assert {:error, %Error{reason: :event_too_large, limit: 10}} =
             SSEDecoder.feed(decoder, "data: two\n\n")
  end

  test "rejects oversized transport chunks before splitting them into lines" do
    decoder = SSEDecoder.new(max_chunk_bytes: 8)

    assert {:error, %Error{reason: :chunk_too_large, limit: 8, actual: 9}} =
             SSEDecoder.feed(decoder, "123456789")
  end

  test "rejects invalid configured limits" do
    assert_raise ArgumentError, fn -> SSEDecoder.new(max_line_bytes: 0) end
    assert_raise ArgumentError, fn -> SSEDecoder.new(max_event_data_bytes: -1) end

    assert_raise ArgumentError, fn ->
      SSEDecoder.new(max_line_bytes: 1_048_577)
    end

    assert_raise ArgumentError, fn ->
      SSEDecoder.new(max_event_data_bytes: 8_388_609)
    end

    assert_raise ArgumentError, fn ->
      SSEDecoder.new(max_chunk_bytes: 8_388_609)
    end
  end

  test "ignores unreasonable retry integers without allocating an unbounded integer" do
    assert [%SSEEvent{retry: nil, data: "ok"}] =
             decode(["retry: 999999999999999999999999999999\ndata: ok\n\n"])
  end

  test "finish accepts a frame boundary and rejects incomplete EOF states" do
    completed = feed!(SSEDecoder.new(), "data: complete\n\n")
    assert {:ok, _decoder, []} = SSEDecoder.finish(completed)

    partial_line = feed!(SSEDecoder.new(), "data: partial")

    assert {:error, %Error{reason: :incomplete_line}} =
             SSEDecoder.finish(partial_line)

    partial_event = feed!(SSEDecoder.new(), "data: partial\n")

    assert {:error, %Error{reason: :incomplete_event}} =
             SSEDecoder.finish(partial_event)
  end

  defp decode(chunks) do
    {decoder, events} =
      Enum.reduce(chunks, {SSEDecoder.new(), []}, fn chunk, {decoder, events} ->
        assert {:ok, decoder, new_events} = SSEDecoder.feed(decoder, chunk)
        {decoder, events ++ new_events}
      end)

    assert {:ok, _decoder, []} = SSEDecoder.finish(decoder)
    events
  end

  defp feed!(decoder, chunk) do
    assert {:ok, decoder, _events} = SSEDecoder.feed(decoder, chunk)
    decoder
  end
end
