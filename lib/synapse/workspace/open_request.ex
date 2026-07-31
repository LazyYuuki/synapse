defmodule Synapse.Workspace.OpenRequest do
  @moduledoc """
  Trusted configuration for opening one real Workspace root.

  `root`, `owner`, limits, and access are application inputs, never model tool
  arguments. The real backend canonicalizes and opens the root; this contract
  validates only bounded shape and trusted ownership data.
  """

  alias Synapse.Workspace.{Access, Limits, Validation}

  @enforce_keys [:root, :owner, :limits, :access]
  defstruct [:root, :owner, :limits, :access]

  @typedoc "Trusted root and maximum authority for one real Workspace handle."
  @type t :: %__MODULE__{
          root: String.t(),
          owner: pid(),
          limits: Limits.t(),
          access: Access.t()
        }

  @typedoc "A validation failure identifying invalid trusted open configuration."
  @type validation_error ::
          {:attributes, :must_be_keyword_or_map}
          | {:unknown_fields, [term()]}
          | {:root, :must_be_bounded_non_empty_string}
          | {:owner, :must_be_pid}
          | {:limits, :must_be_workspace_limits}
          | {:access, :must_be_workspace_access}

  @doc "Validates trusted open configuration without touching the filesystem."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, validation_error()}
  def new(attrs) do
    allowed = [:root, :owner, :limits, :access]

    with {:ok, attrs} <- Validation.attributes(attrs, allowed),
         {:ok, limits} <- normalize_limits(attrs[:limits]),
         true <-
           (Validation.bounded_string?(attrs[:root], limits.max_path_bytes, false) and
              :binary.match(attrs.root, <<0>>) == :nomatch) or
             {:error, {:root, :must_be_bounded_non_empty_string}},
         true <- is_pid(attrs[:owner]) or {:error, {:owner, :must_be_pid}},
         {:ok, access} <- normalize_access(attrs[:access]) do
      {:ok, %__MODULE__{root: attrs.root, owner: attrs.owner, limits: limits, access: access}}
    end
  end

  defp normalize_limits(%Limits{} = limits) do
    case Limits.new(Map.from_struct(limits)) do
      {:ok, limits} -> {:ok, limits}
      {:error, _reason} -> {:error, {:limits, :must_be_workspace_limits}}
    end
  end

  defp normalize_limits(_limits), do: {:error, {:limits, :must_be_workspace_limits}}

  defp normalize_access(%Access{} = access) do
    case Access.new(Map.from_struct(access)) do
      {:ok, access} -> {:ok, access}
      {:error, _reason} -> {:error, {:access, :must_be_workspace_access}}
    end
  end

  defp normalize_access(_access), do: {:error, {:access, :must_be_workspace_access}}
end
