defmodule Synapse.Tool.Dispatcher do
  @moduledoc false

  alias Synapse.Tool.{Bash, DispatchContext, Edit, Read, Validation, Write}
  alias Synapse.Workspace

  alias Synapse.Workspace.{
    EditRequest,
    ProcessSpec,
    ReadRequest,
    Revision,
    WriteRequest
  }

  @type dispatch :: (-> Synapse.Tool.workspace_outcome())

  @doc false
  @spec prepare(module(), term(), DispatchContext.t()) ::
          {:ok, dispatch()} | {:error, :invalid_request | :invalid_dispatch}
  def prepare(module, request, context) do
    with {:ok, context} <- normalize_context(context),
         {:ok, request} <- validate_request(module, request, context) do
      {:ok, dispatch(module, request, context)}
    else
      {:error, :invalid_request} -> {:error, :invalid_request}
      _invalid -> {:error, :invalid_dispatch}
    end
  end

  defp normalize_context(%DispatchContext{} = context),
    do: DispatchContext.new(Map.from_struct(context))

  defp normalize_context(_context), do: {:error, :invalid_dispatch_context}

  defp validate_request(Read, %ReadRequest{} = request, context) do
    with {:ok, request} <-
           ReadRequest.new(Map.from_struct(request), context.workspace.limits),
         true <- byte_size(request.path) <= context.limits.max_path_bytes,
         true <- request.line_count <= context.limits.max_read_lines,
         true <- request.max_bytes <= context.limits.max_read_source_bytes,
         true <- arguments_fit?(read_arguments(request), context) do
      {:ok, request}
    else
      _invalid -> {:error, :invalid_request}
    end
  end

  defp validate_request(Write, %WriteRequest{} = request, context) do
    with {:ok, request} <-
           WriteRequest.new(Map.from_struct(request), context.workspace.limits),
         true <- byte_size(request.path) <= context.limits.max_path_bytes,
         true <- arguments_fit?(write_arguments(request), context) do
      {:ok, request}
    else
      _invalid -> {:error, :invalid_request}
    end
  end

  defp validate_request(Edit, %EditRequest{} = request, context) do
    with {:ok, request} <-
           EditRequest.new(Map.from_struct(request), context.workspace.limits),
         true <- byte_size(request.path) <= context.limits.max_path_bytes,
         true <- arguments_fit?(edit_arguments(request), context) do
      {:ok, request}
    else
      _invalid -> {:error, :invalid_request}
    end
  end

  defp validate_request(Bash, %ProcessSpec{} = request, context) do
    with {:ok, request} <-
           ProcessSpec.new(Map.from_struct(request), context.workspace.limits),
         ["-lc", command] <- request.arguments,
         true <- request.executable == "/bin/bash",
         true <- request.cwd == ".",
         true <- request.mutation == :unknown,
         true <- request.timeout_ms <= context.limits.default_bash_timeout_ms,
         true <- request.inactivity_ms == context.limits.default_bash_inactivity_ms,
         true <- request.max_output_bytes == context.limits.default_bash_output_bytes,
         true <-
           arguments_fit?(%{"command" => command, "timeout_ms" => request.timeout_ms}, context) do
      {:ok, request}
    else
      _invalid -> {:error, :invalid_request}
    end
  end

  defp validate_request(_module, _request, _context), do: {:error, :invalid_dispatch}

  defp dispatch(Read, request, context) do
    fn -> Workspace.read(context.workspace, request, context.operation_context) end
  end

  defp dispatch(Write, request, context) do
    fn -> Workspace.write(context.workspace, request, context.operation_context) end
  end

  defp dispatch(Edit, request, context) do
    fn -> Workspace.edit(context.workspace, request, context.operation_context) end
  end

  defp dispatch(Bash, request, context) do
    fn ->
      Workspace.run(
        context.workspace,
        request,
        fn _event -> :ok end,
        context.operation_context
      )
    end
  end

  defp arguments_fit?(arguments, context) do
    Validation.bounded_json_object?(
      arguments,
      context.limits.max_argument_json_bytes,
      context.limits.max_argument_entries,
      context.limits.max_argument_depth
    )
  end

  defp read_arguments(request) do
    %{
      "path" => request.path,
      "offset" => request.start_line - 1,
      "limit" => request.line_count
    }
  end

  defp write_arguments(request) do
    expected_revision =
      if request.expected_revision == :missing,
        do: "missing",
        else: Revision.encode(request.expected_revision)

    %{
      "path" => request.path,
      "content" => request.content,
      "expected_revision" => expected_revision
    }
  end

  defp edit_arguments(request) do
    %{
      "path" => request.path,
      "old_text" => request.old_text,
      "new_text" => request.new_text,
      "expected_revision" => Revision.encode(request.expected_revision)
    }
  end
end
