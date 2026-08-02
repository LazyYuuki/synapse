defmodule Synapse.Tool.Registry do
  @moduledoc """
  The immutable string-keyed registry for Synapse's four MVP Tools.

  Registry is a pure compiled table. `fetch/1` accepts model-derived strings and
  can return only one of the four fixed specification-bearing modules; it never
  creates atoms, concatenates module names, discovers application modules, or
  performs dynamic registration. Unknown and malformed input returns `:error`
  without echoing the value.

  `specifications/0` returns flat Provider-ready function maps in stable Read,
  Write, Edit, Bash order. Compilation validates count, unique names/modules,
  module/specification agreement, capability/effect policy, per-tool bytes, and
  aggregate encoded bytes. The registry owns no process, ETS table, persistent
  term, mutable state, or extension hook.

  ## Provider request example

      iex> tools = Synapse.Tool.Registry.specifications()
      iex> {:ok, request} = Synapse.Provider.Request.new(
      ...>   model: "configured-model",
      ...>   tools: tools
      ...> )
      iex> Enum.map(request.tools, & &1["name"])
      ["read", "write", "edit", "bash"]
  """

  alias Synapse.Tool.{Bash, Edit, Limits, Read, Spec, Validation, Write}

  @limits Limits.default()
  @entries [
    {"read", Read, :fs_read, :read_only, Read.specification()},
    {"write", Write, :fs_write, :mutation, Write.specification()},
    {"edit", Edit, :fs_write, :mutation, Edit.specification()},
    {"bash", Bash, :process_exec, :unknown, Bash.specification()}
  ]

  @names Enum.map(@entries, &elem(&1, 0))
  @modules Enum.map(@entries, &elem(&1, 1))

  if length(@entries) != 4 or length(@entries) > @limits.max_registered_tools do
    raise "invalid static Tool registry count"
  end

  if length(Enum.uniq(@names)) != length(@names) or
       length(Enum.uniq(@modules)) != length(@modules) do
    raise "duplicate static Tool registry name or module"
  end

  Enum.each(@entries, fn {name, module, capability, effect, specification} ->
    unless function_exported?(module, :specification, 0) do
      raise "static Tool registry module has no specification"
    end

    case {module.specification(), Spec.new(Map.from_struct(specification), @limits)} do
      {^specification, {:ok, %Spec{name: ^name, capability: ^capability, effect: ^effect}}} ->
        :ok

      _invalid ->
        raise "static Tool registry specification mismatch"
    end
  end)

  @registry Map.new(@entries, fn {name, module, _capability, _effect, _specification} ->
              {name, module}
            end)

  @specifications Enum.map(@entries, fn {_name, _module, _capability, _effect, specification} ->
                    {:ok, provider_specification} = Spec.to_provider(specification, @limits)
                    provider_specification
                  end)

  @aggregate_bytes length(@specifications) * @limits.max_schema_bytes_per_tool +
                     length(@specifications) + 1

  unless match?(
           {:ok, _bytes},
           Validation.bounded_json_bytes(
             @specifications,
             @aggregate_bytes,
             @aggregate_bytes,
             5
           )
         ) do
    raise "static Tool registry specifications exceed the aggregate ceiling"
  end

  @doc "Returns Provider-ready strict function maps in stable Read, Write, Edit, Bash order."
  @spec specifications() :: [Synapse.Tool.json_object()]
  def specifications, do: @specifications

  @doc """
  Looks up one exact static Tool name without creating atoms or modules.

  Known names return `{:ok, module}`. Unknown, empty, invalid UTF-8, overlong, and
  non-string values return `:error`.
  """
  @spec fetch(term()) :: {:ok, module()} | :error
  def fetch(name) when is_binary(name) do
    if Validation.identifier?(name, @limits.max_tool_name_bytes),
      do: Map.fetch(@registry, name),
      else: :error
  end

  def fetch(_name), do: :error
end
