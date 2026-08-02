defmodule Synapse.Tool.RegistryTest do
  use ExUnit.Case, async: false

  alias Synapse.Tool.{Bash, Edit, Read, Registry, Write}

  test "looks up only the four exact fixed string names" do
    assert Registry.fetch("read") == {:ok, Read}
    assert Registry.fetch("write") == {:ok, Write}
    assert Registry.fetch("edit") == {:ok, Edit}
    assert Registry.fetch("bash") == {:ok, Bash}

    invalid = [
      "unknown",
      "",
      "   ",
      <<255>>,
      String.duplicate("x", 65),
      :read,
      Read,
      nil,
      1,
      {:read},
      ["read"],
      %{"name" => "read"}
    ]

    Enum.each(invalid, &assert(Registry.fetch(&1) == :error))
  end

  test "unknown model names do not allocate atoms" do
    Registry.specifications()
    Registry.fetch("warm-unknown")
    Read.specification()
    Write.specification()
    Edit.specification()
    Bash.specification()
    :erlang.garbage_collect()

    before_count = :erlang.system_info(:atom_count)

    Enum.each(1..5_000, fn index ->
      assert Registry.fetch("unknown-tool-#{index}") == :error
    end)

    assert :erlang.system_info(:atom_count) == before_count
  end

  test "registry has stable unique module/name pairing and no mutable named state" do
    names = Enum.map(Registry.specifications(), & &1["name"])

    modules =
      Enum.map(names, fn name ->
        {:ok, module} = Registry.fetch(name)
        module
      end)

    assert names == ~w(read write edit bash)
    assert Enum.uniq(names) == names
    assert Enum.uniq(modules) == modules

    Enum.zip(names, modules)
    |> Enum.each(fn {name, module} -> assert module.specification().name == name end)

    assert Process.whereis(Registry) == nil
    assert :ets.whereis(Registry) == :undefined
    assert Registry.__info__(:functions) |> Enum.sort() == [fetch: 1, specifications: 0]
  end

  test "Phase 2 source contains no dynamic dispatch or mutable registry primitive" do
    source_files = ~w(spec read write edit bash registry)

    forbidden = [
      "String.to_atom",
      "String.to_existing_atom",
      "binary_to_atom",
      "list_to_atom",
      ":erlang.binary_to_atom",
      ":erlang.list_to_atom",
      ":erlang.apply",
      "Module.concat",
      "Module.safe_concat",
      "apply(",
      "GenServer",
      ":ets.",
      ":persistent_term",
      "Process.register"
    ]

    Enum.each(source_files, fn name ->
      source = File.read!(Path.join([__DIR__, "..", "lib", "synapse", "tool", name <> ".ex"]))

      Enum.each(forbidden, fn pattern ->
        refute source =~ pattern
      end)
    end)
  end
end
