defmodule Synapse.Workspace.Revision do
  @moduledoc """
  A versioned opaque identity for one observed Workspace file state.

  Workspace producers calculate the HMAC-backed `wsr1` value from file content,
  metadata, path, and a per-handle key. Callers may encode it for a Tool result
  and parse it back for a later write or edit. Parsing validates representation,
  not freshness or ownership; a later mutation phase will verify those before
  committing a write or edit. Revisions are handle-local and path-scoped,
  non-durable, redacted by ordinary inspection, and are not locks or history.
  """

  @prefix "wsr1."
  @mac_bytes 32

  @enforce_keys [:encoded]
  defstruct [:encoded]

  @typedoc "An in-memory stale-write guard verified by the Workspace that issued it."
  @opaque t :: %__MODULE__{encoded: String.t()}

  @doc "Parses one syntactically valid `wsr1` revision without checking freshness."
  @spec parse(String.t()) :: {:ok, t()} | {:error, :invalid_revision}
  def parse(<<@prefix, encoded::binary>> = revision) when byte_size(encoded) == 43 do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, mac} when byte_size(mac) == @mac_bytes ->
        if Base.url_encode64(mac, padding: false) == encoded,
          do: {:ok, %__MODULE__{encoded: revision}},
          else: {:error, :invalid_revision}

      _invalid ->
        {:error, :invalid_revision}
    end
  end

  def parse(_revision), do: {:error, :invalid_revision}

  @doc "Returns the versioned string passed between Workspace and model-facing Tool data."
  @spec encode(t()) :: String.t()
  def encode(%__MODULE__{encoded: encoded}), do: encoded

  @doc "Returns whether a term is a syntactically valid revision struct."
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{encoded: encoded}), do: match?({:ok, %__MODULE__{}}, parse(encoded))
  def valid?(_revision), do: false

  @doc "Builds a revision from a 32-byte HMAC produced by a trusted Workspace backend."
  @spec from_mac(binary()) :: {:ok, t()} | {:error, :invalid_mac}
  def from_mac(mac) when is_binary(mac) and byte_size(mac) == @mac_bytes do
    encoded = @prefix <> Base.url_encode64(mac, padding: false)
    {:ok, %__MODULE__{encoded: encoded}}
  end

  def from_mac(_mac), do: {:error, :invalid_mac}
end

defimpl Inspect, for: Synapse.Workspace.Revision do
  def inspect(_revision, _options), do: "#Synapse.Workspace.Revision<redacted>"
end
