defmodule Synapse.Tool.Edit do
  @moduledoc """
  Implements canonical revision-checked exact-one literal Edit.

  Edit requires non-empty literal old text, replacement text that may be empty,
  and the exact canonical revision returned by Read. Preparation revalidates the
  complete bounded Call and returns one typed `Workspace.EditRequest`, without
  regex, fuzzy matching, patch parsing, merge, or retry. Workspace checks revision
  freshness before match disclosure and applies exactly one occurrence or none.
  Executor's static Dispatcher owns the write-only authority and actual mutation.

  Stale, zero-match, multiple-match, and generated-size conflicts are known not
  applied. Post-dispatch uncertainty is ambiguous; the adapter never rereads,
  merges, rebases, or retries. See `docs/learning/TOOL-SYSTEM.md`.
  """

  @behaviour Synapse.Tool

  alias Synapse.Tool.{Call, Limits, Presentation, Spec}
  alias Synapse.Workspace.{EditRequest, Revision}

  @argument_names ~w(path old_text new_text expected_revision)

  {:ok, specification} =
    Spec.new(%{
      name: "edit",
      description:
        "Replace exactly one literal text occurrence in one revision of a workspace file.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "Relative workspace file path."
          },
          "old_text" => %{
            "type" => "string",
            "description" => "Non-empty literal text that must occur exactly once."
          },
          "new_text" => %{
            "type" => "string",
            "description" => "Literal replacement text; it may be empty."
          },
          "expected_revision" => %{
            "type" => "string",
            "description" => "Exact wsr1 revision returned by read."
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
  @doc "Returns the immutable strict Edit specification used by the static Registry."
  @spec specification() :: Spec.t()
  def specification, do: @specification

  @impl true
  @doc "Validates exact Edit arguments and prepares one revision-checked EditRequest."
  @spec prepare(Call.t(), Limits.t()) ::
          {:ok, EditRequest.t()} | {:error, :invalid_arguments}
  def prepare(
        %Call{
          name: "edit",
          arguments:
            %{
              "path" => path,
              "old_text" => old_text,
              "new_text" => new_text,
              "expected_revision" => expected_revision
            } = arguments
        } = call,
        %Limits{} = limits
      )
      when map_size(arguments) == 4 do
    with {:ok, limits} <- Limits.new(Map.from_struct(limits)),
         {:ok, _call} <- Call.new(Map.from_struct(call), limits),
         true <- is_binary(path) and byte_size(path) <= limits.max_path_bytes,
         true <- is_binary(old_text) and old_text != "",
         true <- is_binary(new_text),
         {:ok, revision} <- Revision.parse(expected_revision),
         {:ok, request} <-
           EditRequest.new(
             path: path,
             old_text: old_text,
             new_text: new_text,
             expected_revision: revision
           ) do
      {:ok, request}
    else
      _invalid -> {:error, :invalid_arguments}
    end
  end

  def prepare(_call, _limits), do: {:error, :invalid_arguments}

  @impl true
  @doc "Presents one retained Workspace Edit outcome as a bounded paired Result."
  @spec present(Call.t(), Synapse.Tool.workspace_outcome(), Limits.t()) ::
          Synapse.Tool.Result.t()
  def present(%Call{call_id: call_id}, outcome, %Limits{} = limits),
    do: Presentation.edit(call_id, outcome, limits)
end
