# Private canonical HMAC payload used by real Workspace handles.
defmodule Synapse.Workspace.RevisionAlgorithm do
  @moduledoc false

  alias Synapse.Workspace.Revision
  alias Synapse.Workspace.Path

  @payload_version 1
  @key_bytes 32
  @digest_bytes 32

  @spec calculate(binary(), String.t(), File.Stat.t(), binary()) ::
          {:ok, Revision.t()} | {:error, :invalid_revision_input}
  def calculate(key, relative_path, %File.Stat{} = stat, digest)
      when is_binary(key) and byte_size(key) == @key_bytes and is_binary(relative_path) and
             is_binary(digest) and byte_size(digest) == @digest_bytes do
    with {:ok, normalized} <- Path.normalize(relative_path, 4_096),
         true <- normalized == relative_path do
      payload =
        :erlang.term_to_binary(
          {
            :synapse_workspace_revision,
            @payload_version,
            normalized,
            {
              stat.major_device,
              stat.minor_device,
              stat.inode,
              stat.type,
              stat.links,
              stat.size,
              stat.mode,
              stat.mtime,
              stat.ctime
            },
            digest
          },
          [:deterministic]
        )

      key
      |> then(&:crypto.mac(:hmac, :sha256, &1, payload))
      |> Revision.from_mac()
    else
      _invalid -> {:error, :invalid_revision_input}
    end
  end

  def calculate(_key, _relative_path, _stat, _digest),
    do: {:error, :invalid_revision_input}

  @spec matches?(Revision.t(), binary(), String.t(), File.Stat.t(), binary()) :: boolean()
  def matches?(%Revision{} = expected, key, relative_path, stat, digest) do
    case {Revision.valid?(expected), calculate(key, relative_path, stat, digest)} do
      {true, {:ok, current}} ->
        :crypto.hash_equals(Revision.encode(expected), Revision.encode(current))

      _invalid ->
        false
    end
  end

  def matches?(_expected, _key, _relative_path, _stat, _digest), do: false
end
