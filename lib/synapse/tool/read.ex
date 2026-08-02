defmodule Synapse.Tool.Read do
  @moduledoc """
  Implements the canonical bounded model-facing Read Tool.

  Read exposes a zero-based nullable offset and nullable line limit. Preparation
  accepts exactly the schema fields, maps them to a one-based bounded Workspace
  ReadRequest, and never receives or invokes a Workspace Handle. Executor's static
  Dispatcher performs the actual read under reduced authority. Presentation
  returns numbered lines, the opaque revision, direct continuation, and distinct
  source/presentation truncation evidence.

  Malformed arguments fail before dispatch. Workspace read, cancellation, and
  backend failures are ordinary known errors because Read has no side effect;
  Executor never retries automatically. See `docs/learning/TOOL-SYSTEM.md`.
  """

  @behaviour Synapse.Tool

  alias Synapse.Tool.{Call, Limits, Presentation, Spec, Validation}
  alias Synapse.Workspace.ReadRequest

  @argument_names ~w(path offset limit)

  {:ok, specification} =
    Spec.new(%{
      name: "read",
      description:
        "Read a bounded window of numbered lines from one workspace text file. Use the returned revision for write or edit.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "Relative workspace file path."
          },
          "offset" => %{
            "type" => ["integer", "null"],
            "minimum" => 0,
            "description" => "Zero-based line offset, or null for 0."
          },
          "limit" => %{
            "type" => ["integer", "null"],
            "minimum" => 1,
            "maximum" => 1_000,
            "description" => "Maximum lines, or null for the trusted default."
          }
        },
        "required" => @argument_names,
        "additionalProperties" => false
      },
      capability: :fs_read,
      effect: :read_only
    })

  @specification specification

  @impl true
  @doc "Returns the immutable strict Read specification used by the static Registry."
  @spec specification() :: Spec.t()
  def specification, do: @specification

  @impl true
  @doc "Validates exact Read arguments and prepares one bounded Workspace ReadRequest."
  @spec prepare(Call.t(), Limits.t()) ::
          {:ok, ReadRequest.t()} | {:error, :invalid_arguments}
  def prepare(
        %Call{
          name: "read",
          arguments: %{"path" => path, "offset" => offset, "limit" => limit} = arguments
        },
        %Limits{} = limits
      )
      when map_size(arguments) == 3 do
    with {:ok, limits} <- Limits.new(Map.from_struct(limits)),
         true <- is_binary(path) and byte_size(path) <= limits.max_path_bytes,
         {:ok, offset} <- normalize_offset(offset),
         {:ok, line_count} <- normalize_line_count(limit, limits),
         {:ok, request} <-
           ReadRequest.new(
             path: path,
             start_line: offset + 1,
             line_count: line_count,
             max_bytes: limits.default_read_source_bytes
           ) do
      {:ok, request}
    else
      _invalid -> {:error, :invalid_arguments}
    end
  end

  def prepare(_call, _limits), do: {:error, :invalid_arguments}

  @impl true
  @doc "Presents one retained Workspace Read outcome as a bounded paired Result."
  @spec present(Call.t(), Synapse.Tool.workspace_outcome(), Limits.t()) ::
          Synapse.Tool.Result.t()
  def present(%Call{call_id: call_id}, outcome, %Limits{} = limits),
    do: Presentation.read(call_id, outcome, limits)

  defp normalize_offset(nil), do: {:ok, 0}

  defp normalize_offset(offset) do
    if is_integer(offset) and offset >= 0 and Validation.int64?(offset) and
         Validation.int64?(offset + 1),
       do: {:ok, offset},
       else: {:error, :invalid_offset}
  end

  defp normalize_line_count(nil, limits), do: {:ok, limits.default_read_lines}

  defp normalize_line_count(line_count, limits) do
    if is_integer(line_count) and line_count > 0 and line_count <= limits.max_read_lines,
      do: {:ok, line_count},
      else: {:error, :invalid_line_count}
  end
end
