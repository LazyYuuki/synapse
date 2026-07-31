defmodule Synapse.Provider.CredentialsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  require Logger

  alias Synapse.Provider.{Credentials, Error, Request}
  alias Synapse.Provider.Event.Diagnostic

  @test_key "tokamak-test-key-that-must-not-appear"

  test "returns a sanitized configuration error when the key is missing" do
    assert {:error, error} = Credentials.resolve("operation-1", fn _name -> nil end)

    assert %Error{
             kind: :configuration,
             message: "Tokamak API key is not configured",
             retryable: false,
             output_started: false,
             operation_id: "operation-1"
           } = error

    assert error.details == %{"environment_variable" => "TOKAMAK_API_KEY"}
    refute inspect(error) =~ @test_key
  end

  test "rejects empty, whitespace-only, and invalid UTF-8 values" do
    for value <- ["", " \t\n", <<255>>] do
      assert {:error, %Error{kind: :configuration}} =
               Credentials.resolve("operation-1", fn "TOKAMAK_API_KEY" -> value end)
    end
  end

  test "resolves a test key without modifying process environment" do
    parent = self()

    source = fn name ->
      send(parent, {:credential_lookup, name})
      "  " <> @test_key <> "\n"
    end

    assert {:ok, secret} = Credentials.resolve("operation-1", source)
    assert_receive {:credential_lookup, "TOKAMAK_API_KEY"}

    assert Credentials.with_value(secret, fn value ->
             assert value == @test_key
             byte_size(value)
           end) == byte_size(@test_key)
  end

  test "redacts the secret wrapper under default and expanded inspection" do
    assert {:ok, secret} =
             Credentials.resolve("operation-1", fn _name -> @test_key end)

    assert inspect(secret) == "#Synapse.Provider.Credentials.Secret<redacted>"
    refute inspect(secret, structs: false) =~ @test_key
    refute inspect(secret, limit: :infinity, printable_limit: :infinity) =~ @test_key
  end

  test "Provider contracts cannot contain the resolved key" do
    assert {:ok, secret} =
             Credentials.resolve("operation-1", fn _name -> @test_key end)

    assert {:ok, request} = Request.new(model: "configured-model")

    event = %Diagnostic{
      code: "credential_test",
      message: "Credential resolution completed"
    }

    error = %Error{
      kind: :configuration,
      message: "Credential unavailable",
      retryable: false,
      output_started: false,
      operation_id: "operation-1"
    }

    inspected = inspect({secret, request, event, error})

    refute inspected =~ @test_key
    refute :api_key in Map.keys(request)
    refute :authorization in Map.keys(request)
    refute :credential in Map.keys(event)
    refute :credential in Map.keys(error)
  end

  test "captured Logger output contains no resolved key" do
    log =
      capture_log(fn ->
        assert {:ok, secret} =
                 Credentials.resolve("operation-1", fn _name -> @test_key end)

        Logger.warning("resolved credential: #{inspect(secret)}")

        Credentials.with_value(secret, fn _value ->
          Logger.warning("constructing provider authorization")
        end)
      end)

    refute log =~ @test_key
    assert log =~ "Secret<redacted>"
  end

  test "rejects an invalid operation ID before reading the source" do
    source = fn _name -> flunk("source must not be called") end

    assert_raise ArgumentError, fn -> Credentials.resolve(" ", source) end
  end
end
