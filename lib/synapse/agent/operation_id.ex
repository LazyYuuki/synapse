defmodule Synapse.Agent.OperationId do
  @moduledoc """
  Pure bounded operation identity derived from trusted run identity and ordinals.

  Agent uses a lowercase SHA-256 digest of the validated Run ID so operation IDs
  expose no prompt, path, model output, Tool arguments, or arbitrary Provider
  identifier. Ordinals are padded to four digits for stable ordinary-run fixtures
  and may grow within the signed accounting range.

  ## Example

      iex> {:ok, id} = Synapse.Agent.OperationId.provider("run-doc", 1, 1)
      iex> String.starts_with?(id, "provider-") and String.ends_with?(id, "-t0001-a0001")
      true
  """

  alias Synapse.Tool.Validation

  @max_run_id_bytes 256

  @typedoc "An invalid trusted Run ID or one-based signed ordinal."
  @type error ::
          {:run_id, :must_be_bounded_non_empty_utf8_identifier}
          | {:turn, :must_be_one_based_ordinal}
          | {:attempt, :must_be_one_based_ordinal}
          | {:call, :must_be_one_based_ordinal}

  @doc "Builds one Provider-attempt operation ID."
  @spec provider(String.t(), pos_integer(), pos_integer()) ::
          {:ok, String.t()} | {:error, error()}
  def provider(run_id, turn, attempt) do
    with :ok <- validate_run_id(run_id),
         :ok <- validate_ordinal(:turn, turn),
         :ok <- validate_ordinal(:attempt, attempt) do
      {:ok, "provider-#{digest(run_id)}-t#{ordinal(turn)}-a#{ordinal(attempt)}"}
    end
  end

  @doc "Builds one Tool-call operation ID for sequential execution in a logical turn."
  @spec tool(String.t(), pos_integer(), pos_integer()) ::
          {:ok, String.t()} | {:error, error()}
  def tool(run_id, turn, call) do
    with :ok <- validate_run_id(run_id),
         :ok <- validate_ordinal(:turn, turn),
         :ok <- validate_ordinal(:call, call) do
      {:ok, "tool-#{digest(run_id)}-t#{ordinal(turn)}-c#{ordinal(call)}"}
    end
  end

  defp validate_run_id(run_id) do
    if Validation.identifier?(run_id, @max_run_id_bytes),
      do: :ok,
      else: {:error, {:run_id, :must_be_bounded_non_empty_utf8_identifier}}
  end

  defp validate_ordinal(_field, value)
       when is_integer(value) and value >= 1 and value <= 9_223_372_036_854_775_807,
       do: :ok

  defp validate_ordinal(field, _value),
    do: {:error, {field, :must_be_one_based_ordinal}}

  defp digest(run_id),
    do: :crypto.hash(:sha256, run_id) |> Base.encode16(case: :lower)

  defp ordinal(value), do: value |> Integer.to_string() |> String.pad_leading(4, "0")
end
