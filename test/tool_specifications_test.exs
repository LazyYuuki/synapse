defmodule Synapse.Tool.SpecificationsTest do
  use ExUnit.Case, async: true

  alias Synapse.Provider.{Request, ResponsesCodec}

  alias Synapse.Tool.{
    Bash,
    Edit,
    Limits,
    Read,
    Registry,
    Spec,
    Validation,
    Write
  }

  doctest Registry

  test "built-in modules own the exact reviewed specifications" do
    expected = fixture("all_tools_request")["tools"]

    modules = [
      {Read, :fs_read, :read_only},
      {Write, :fs_write, :mutation},
      {Edit, :fs_write, :mutation},
      {Bash, :process_exec, :unknown}
    ]

    Enum.zip(modules, expected)
    |> Enum.each(fn {{module, capability, effect}, expected_tool} ->
      assert %Spec{capability: ^capability, effect: ^effect} = spec = module.specification()
      assert spec.name == expected_tool["name"]
      assert {:ok, provider_spec} = Spec.to_provider(spec)
      assert provider_spec == expected_tool
      refute Map.has_key?(provider_spec, "capability")
      refute Map.has_key?(provider_spec, "effect")
      refute Map.has_key?(provider_spec, "module")
    end)
  end

  test "Provider projection rejects forged or invalid Spec structs" do
    valid = Read.specification()

    assert {:error, {:name, :must_be_bounded_non_empty_utf8_identifier}} =
             Spec.to_provider(%Spec{valid | name: "bad\nname"})

    assert {:error, {:parameters, :must_be_complete_strict_flat_object_schema}} =
             Spec.to_provider(%Spec{valid | parameters: %{"type" => "string"}})

    assert {:error, {:attributes, :must_be_keyword_or_map}} = Spec.to_provider(%{})
  end

  test "registry specifications match the aggregate and single-read fixtures exactly" do
    expected = fixture("all_tools_request")["tools"]
    [expected_read] = fixture("one_tool_request")["tools"]

    assert Registry.specifications() == expected
    assert Registry.specifications() |> hd() == expected_read
    assert Enum.map(Registry.specifications(), & &1["name"]) == ~w(read write edit bash)
  end

  test "every schema remains strict, closed, bounded, and field-complete" do
    limits = Limits.default()
    specifications = Registry.specifications()

    Enum.each(specifications, fn tool ->
      assert MapSet.new(Map.keys(tool)) ==
               MapSet.new(~w(type name description parameters strict))

      assert tool["type"] == "function"
      assert tool["strict"] == true
      assert tool["parameters"]["type"] == "object"
      assert tool["parameters"]["additionalProperties"] == false

      properties = tool["parameters"]["properties"]
      required = tool["parameters"]["required"]
      assert MapSet.new(required) == MapSet.new(Map.keys(properties))

      assert {:ok, _bytes} =
               Validation.bounded_json_bytes(
                 tool,
                 limits.max_schema_bytes_per_tool,
                 limits.max_schema_bytes_per_tool,
                 4
               )

      assert all_object_keys_are_strings?(tool)
    end)

    aggregate_limit =
      length(specifications) * limits.max_schema_bytes_per_tool + length(specifications) + 1

    assert {:ok, _bytes} =
             Validation.bounded_json_bytes(
               specifications,
               aggregate_limit,
               aggregate_limit,
               5
             )
  end

  test "nullable fields and hard model bounds match the Phase 0 contract" do
    by_name = Map.new(Registry.specifications(), &{&1["name"], &1})

    read_properties = by_name["read"]["parameters"]["properties"]
    write_properties = by_name["write"]["parameters"]["properties"]
    edit_properties = by_name["edit"]["parameters"]["properties"]
    bash_properties = by_name["bash"]["parameters"]["properties"]

    assert read_properties["offset"]["type"] == ["integer", "null"]
    assert read_properties["limit"]["type"] == ["integer", "null"]
    assert read_properties["limit"]["maximum"] == 1_000
    assert bash_properties["timeout_ms"]["type"] == ["integer", "null"]
    assert bash_properties["timeout_ms"]["maximum"] == 900_000

    refute Enum.any?(write_properties, fn {_name, property} -> is_list(property["type"]) end)
    refute Enum.any?(edit_properties, fn {_name, property} -> is_list(property["type"]) end)
  end

  test "Provider Request and ResponsesCodec preserve registry schema data" do
    tools = Registry.specifications()
    expected = fixture("all_tools_request")

    assert {:ok, request} = Request.new(model: "configured-model", tools: tools)
    assert {:ok, ^expected} = ResponsesCodec.encode(request)

    Enum.each(tools, fn tool ->
      assert {:ok, request} = Request.new(model: "configured-model", tools: [tool])
      assert {:ok, encoded} = ResponsesCodec.encode(request)
      assert encoded["tools"] == [tool]
    end)
  end

  defp all_object_keys_are_strings?(value) when is_map(value) do
    Enum.all?(value, fn {key, item} -> is_binary(key) and all_object_keys_are_strings?(item) end)
  end

  defp all_object_keys_are_strings?(value) when is_list(value),
    do: Enum.all?(value, &all_object_keys_are_strings?/1)

  defp all_object_keys_are_strings?(_value), do: true

  defp fixture(name) do
    path = Path.join([__DIR__, "fixtures", "responses", name <> ".fixture"])
    {fixture, _bindings} = Code.eval_file(path)
    fixture
  end
end
