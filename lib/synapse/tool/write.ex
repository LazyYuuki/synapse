defmodule Synapse.Tool.Write do
  @moduledoc """
  Implements canonical revision-checked whole-file Write.

  Write requires complete UTF-8 content plus either the exact `missing` creation
  sentinel or a canonical revision returned by Read. Preparation revalidates the
  complete bounded Call before retaining content and returns one typed
  `Workspace.WriteRequest`. It provides no blind overwrite, append, directory
  creation, or retry path. Executor's static Dispatcher performs the mutation
  under write-only authority; this adapter never receives a Workspace Handle.

  A stale or expected-existing conflict is known not applied. Any failure after a
  backend may have committed remains ambiguous and requires inspection before a
  new operation; Executor never retries automatically. See
  `docs/learning/TOOL-SYSTEM.md`.
  """

  @behaviour Synapse.Tool

  alias Synapse.Tool.{Call, Limits, Presentation, Spec}
  alias Synapse.Workspace.{Revision, WriteRequest}

  @argument_names ~w(path content expected_revision)

  {:ok, specification} =
    Spec.new(%{
      name: "write",
      description:
        "Create a missing workspace text file or replace one exact revision. Blind overwrite is not supported.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "Relative workspace file path."
          },
          "content" => %{
            "type" => "string",
            "description" => "Complete UTF-8 file content."
          },
          "expected_revision" => %{
            "type" => "string",
            "description" =>
              "Use missing for creation or the exact wsr1 revision returned by read."
          }
        },
        "required" => @argument_names,
        "additionalProperties" => false
      },
      capability: :fs_write,
      effect: :mutation
    })

  @specification specification

  @impl true
  @doc "Returns the immutable strict Write specification used by the static Registry."
  @spec specification() :: Spec.t()
  def specification, do: @specification

  @impl true
  @doc "Validates exact Write arguments and prepares one revision-checked WriteRequest."
  @spec prepare(Call.t(), Limits.t()) ::
          {:ok, WriteRequest.t()} | {:error, :invalid_arguments}
  def prepare(
        %Call{
          name: "write",
          arguments:
            %{
              "path" => path,
              "content" => content,
              "expected_revision" => expected_revision
            } = arguments
        } = call,
        %Limits{} = limits
      )
      when map_size(arguments) == 3 do
    with {:ok, limits} <- Limits.new(Map.from_struct(limits)),
         {:ok, _call} <- Call.new(Map.from_struct(call), limits),
         true <- is_binary(path) and byte_size(path) <= limits.max_path_bytes,
         true <- is_binary(content),
         {:ok, expectation} <- parse_expectation(expected_revision),
         {:ok, request} <-
           WriteRequest.new(
             path: path,
             content: content,
             expected_revision: expectation
           ) do
      {:ok, request}
    else
      _invalid -> {:error, :invalid_arguments}
    end
  end

  def prepare(_call, _limits), do: {:error, :invalid_arguments}

  @impl true
  @doc "Presents one retained Workspace Write outcome as a bounded paired Result."
  @spec present(Call.t(), Synapse.Tool.workspace_outcome(), Limits.t()) ::
          Synapse.Tool.Result.t()
  def present(%Call{call_id: call_id}, outcome, %Limits{} = limits),
    do: Presentation.write(call_id, outcome, limits)

  defp parse_expectation("missing"), do: {:ok, :missing}
  defp parse_expectation(expected_revision), do: Revision.parse(expected_revision)
end
