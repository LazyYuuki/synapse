# Internal whole-file write/edit stage, commit, and confirmation protocol.
defmodule Synapse.Workspace.AtomicWriter do
  @moduledoc false

  alias Synapse.Workspace.{
    Access,
    Diff,
    EditRequest,
    Limits,
    MutationResult,
    OperationContext,
    Path,
    ReadRequest,
    Reader,
    RevisionAlgorithm,
    Root,
    WriteRequest
  }

  @stage_attempts 8

  @type outcome :: :not_applied | :unknown
  @type reason ::
          :expected_missing
          | :stale_revision
          | :no_match
          | :multiple_matches
          | :not_found
          | :symlink
          | :mount_crossing
          | :multiple_hard_links
          | :not_regular_file
          | :file_too_large
          | :invalid_utf8
          | :atomic_commit_failed
          | :durability_unknown
          | :io

  @spec write(Root.t(), binary(), Limits.t(), WriteRequest.t(), String.t(), keyword()) ::
          {:ok, MutationResult.t()} | {:error, reason(), outcome()}
  def write(root, revision_key, limits, request, operation_id, options \\ []) do
    run_tracked(fn committed_key ->
      do_write(root, revision_key, limits, request, operation_id, options, committed_key)
    end)
  end

  @spec edit(Root.t(), binary(), Limits.t(), EditRequest.t(), String.t(), keyword()) ::
          {:ok, MutationResult.t()} | {:error, reason(), outcome()}
  def edit(root, revision_key, limits, request, operation_id, options \\ []) do
    run_tracked(fn committed_key ->
      do_edit(root, revision_key, limits, request, operation_id, options, committed_key)
    end)
  end

  defp run_tracked(operation) do
    committed_key = {__MODULE__, make_ref()}
    Process.put(committed_key, false)

    try do
      operation.(committed_key)
    rescue
      _exception ->
        if Process.get(committed_key),
          do: {:error, :durability_unknown, :unknown},
          else: {:error, :io, :not_applied}
    catch
      _kind, _reason ->
        if Process.get(committed_key),
          do: {:error, :durability_unknown, :unknown},
          else: {:error, :io, :not_applied}
    after
      Process.delete(committed_key)
    end
  end

  defp do_edit(root, key, limits, request, operation_id, options, committed_key) do
    with :ok <- checkpoint(options, :before_stage),
         {:ok, initial} <- expected_state(root, key, limits, request),
         {:ok, content} <- exact_replacement(initial.observation.content, request, limits),
         write_request <- %WriteRequest{
           path: request.path,
           content: content,
           expected_revision: request.expected_revision
         },
         result <- maybe_noop(initial, write_request, operation_id, limits) do
      case result do
        {:ok, %MutationResult{}} = success ->
          success

        :changed ->
          commit_changed(
            root,
            key,
            limits,
            write_request,
            operation_id,
            initial,
            options,
            committed_key
          )
      end
    else
      {:error, reason} -> {:error, reason, :not_applied}
    end
  end

  defp do_write(root, key, limits, request, operation_id, options, committed_key) do
    with :ok <- checkpoint(options, :before_stage),
         {:ok, initial} <- expected_state(root, key, limits, request),
         result <- maybe_noop(initial, request, operation_id, limits) do
      case result do
        {:ok, %MutationResult{}} = success ->
          success

        :changed ->
          commit_changed(
            root,
            key,
            limits,
            request,
            operation_id,
            initial,
            options,
            committed_key
          )
      end
    else
      {:error, reason} -> {:error, reason, :not_applied}
    end
  end

  defp maybe_noop(
         %{kind: :existing, observation: observation, revision: revision},
         request,
         operation_id,
         limits
       ) do
    if observation.content == request.content do
      MutationResult.new(
        %{
          operation_id: operation_id,
          path: request.path,
          previous_revision: revision,
          revision: revision,
          bytes_written: 0,
          changed: false,
          diff: "",
          diff_truncated: false
        },
        limits
      )
    else
      :changed
    end
  end

  defp maybe_noop(%{kind: :missing}, _request, _operation_id, _limits), do: :changed

  defp commit_changed(root, key, limits, request, operation_id, initial, options, committed_key) do
    old_content = if initial.kind == :existing, do: initial.observation.content, else: ""
    previous = if initial.kind == :existing, do: initial.revision, else: :missing
    previous_kind = if initial.kind == :existing, do: :existing, else: :missing

    {diff, diff_truncated} =
      Diff.build(old_content, request.content, request.path, limits.max_diff_bytes, previous_kind)

    case unique_stage(initial.resolved.absolute) do
      {:ok, stage_path} ->
        cleanup_guard = start_cleanup_guard(stage_path, self())

        result =
          run_with_stage_cleanup(cleanup_guard, stage_path, options, fn ->
            prepare_and_commit_stage(
              stage_path,
              root,
              key,
              limits,
              request,
              initial,
              options,
              committed_key
            )
          end)

        case result do
          {:ok, revision} ->
            MutationResult.new(
              %{
                operation_id: operation_id,
                path: request.path,
                previous_revision: previous,
                revision: revision,
                bytes_written: byte_size(request.content),
                changed: true,
                diff: diff,
                diff_truncated: diff_truncated
              },
              limits
            )

          {:error, reason, outcome} ->
            {:error, reason, outcome}
        end

      {:error, reason} ->
        {:error, reason, :not_applied}
    end
  end

  defp prepare_and_commit_stage(
         stage_path,
         root,
         key,
         limits,
         request,
         initial,
         options,
         committed_key
       ) do
    with :ok <- write_stage(stage_path, request.content, initial, options),
         :ok <- checkpoint(options, :before_recheck),
         {:ok, final_state} <- expected_state(root, key, limits, request),
         true <- same_expectation?(initial, final_state) or {:error, :stale_revision},
         :ok <- checkpoint(options, :before_commit),
         :ok <- checkpoint(options, :commit),
         :ok <- commit(stage_path, final_state.resolved.absolute, initial.kind),
         _true <- Process.put(committed_key, true),
         :ok <- checkpoint(options, :after_commit),
         :ok <- finish_creation_stage(stage_path, initial.kind, options),
         :ok <- checkpoint(options, :confirmation),
         {:ok, revision} <- confirm(root, key, limits, request) do
      {:ok, revision}
    else
      {:error, :expected_missing} ->
        {:error, :expected_missing, :not_applied}

      {:error, :stale_revision} ->
        {:error, :stale_revision, :not_applied}

      {:error, :atomic_commit_failed} ->
        {:error, :atomic_commit_failed, :not_applied}

      {:error, reason} ->
        if Process.get(committed_key),
          do: {:error, :durability_unknown, :unknown},
          else: {:error, reason, :not_applied}
    end
  end

  defp expected_state(root, _key, limits, %WriteRequest{expected_revision: :missing} = request) do
    case Path.resolve(root, request.path, limits.max_path_bytes, :file, allow_missing: true) do
      {:ok, %{type: :missing} = resolved} ->
        {:ok, %{kind: :missing, resolved: resolved}}

      {:ok, _existing} ->
        {:error, :expected_missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp expected_state(root, key, limits, request)
       when is_struct(request, WriteRequest) or is_struct(request, EditRequest) do
    case observe(root, limits, request.path) do
      {:ok, resolved, observation} ->
        if RevisionAlgorithm.matches?(
             request.expected_revision,
             key,
             resolved.relative,
             observation.stat,
             observation.digest
           ) do
          {:ok,
           %{
             kind: :existing,
             resolved: resolved,
             observation: observation,
             revision: request.expected_revision
           }}
        else
          {:error, :stale_revision}
        end

      {:error, reason} when reason in [:not_found, :file_changed] ->
        {:error, :stale_revision}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp exact_replacement(content, request, limits) do
    case :binary.match(content, request.old_text) do
      :nomatch ->
        {:error, :no_match}

      {index, old_bytes} ->
        if another_match?(content, request.old_text, index) do
          {:error, :multiple_matches}
        else
          build_replacement(content, request.new_text, index, old_bytes, limits)
        end
    end
  end

  defp another_match?(content, old_text, first_index) do
    next_start = first_index + 1
    rest = binary_part(content, next_start, byte_size(content) - next_start)
    :binary.match(rest, old_text) != :nomatch
  end

  defp build_replacement(content, new_text, index, old_bytes, limits) do
    generated_bytes = byte_size(content) - old_bytes + byte_size(new_text)

    if generated_bytes > limits.max_file_bytes do
      {:error, :file_too_large}
    else
      suffix_start = index + old_bytes

      generated =
        IO.iodata_to_binary([
          binary_part(content, 0, index),
          new_text,
          binary_part(content, suffix_start, byte_size(content) - suffix_start)
        ])

      cond do
        byte_size(generated) != generated_bytes -> {:error, :io}
        not String.valid?(generated) -> {:error, :invalid_utf8}
        true -> {:ok, generated}
      end
    end
  end

  defp observe(root, limits, path) do
    with {:ok, resolved} <- Path.resolve(root, path, limits.max_path_bytes, :file),
         {:ok, observation} <-
           Reader.read(
             resolved,
             %ReadRequest{path: path, start_line: 1, line_count: 1, max_bytes: 1},
             internal_context(),
             limits
           ) do
      {:ok, resolved, observation}
    end
  end

  defp same_expectation?(%{kind: :missing}, %{kind: :missing}), do: true

  defp same_expectation?(%{kind: :existing, revision: revision}, %{
         kind: :existing,
         revision: revision
       }),
       do: true

  defp same_expectation?(_initial, _final), do: false

  defp write_stage(stage_path, content, initial, options) do
    with :ok <- checkpoint(options, :stage_open),
         {:ok, descriptor} <- File.open(stage_path, [:write, :raw, :binary, :exclusive]) do
      try do
        result =
          with :ok <- checkpoint(options, :stage_stat),
               {:ok, stage_stat} <- File.stat(stage_path),
               :ok <- checkpoint(options, :private_mode),
               :ok <- File.chmod(stage_path, 0o600),
               :ok <- write_stage_content(descriptor, content, options),
               :ok <- checkpoint(options, :stage_written),
               :ok <- checkpoint(options, :apply_mode),
               :ok <- apply_mode(stage_path, initial, stage_stat.mode),
               :ok <- checkpoint(options, :verify_stage),
               :ok <- verify_stage(stage_path, byte_size(content)),
               :ok <- checkpoint(options, :validation),
               :ok <- checkpoint(options, :sync),
               :ok <- :file.sync(descriptor) do
            :ok
          else
            {:error, _reason} -> {:error, :io}
            _invalid -> {:error, :io}
          end

        close_checkpoint = checkpoint(options, :stage_close)
        close_result = :file.close(descriptor)

        if result == :ok and close_checkpoint == :ok and close_result == :ok,
          do: :ok,
          else: {:error, :io}
      after
        _already_closed_or_cleanup = :file.close(descriptor)
      end
    else
      {:error, _reason} -> {:error, :io}
    end
  end

  defp write_stage_content(descriptor, content, options) do
    if Keyword.get(options, :fail_at) == :during_write do
      partial_bytes = div(byte_size(content), 2)
      partial = binary_part(content, 0, partial_bytes)
      _result = :file.write(descriptor, partial)
      {:error, :injected}
    else
      :file.write(descriptor, content)
    end
  end

  defp apply_mode(stage_path, %{kind: :missing}, default_mode),
    do: File.chmod(stage_path, Bitwise.band(default_mode, 0o7777))

  defp apply_mode(stage_path, %{kind: :existing, observation: observation}, _default_mode),
    do: File.chmod(stage_path, Bitwise.band(observation.stat.mode, 0o7777))

  defp verify_stage(stage_path, expected_bytes) do
    case File.stat(stage_path) do
      {:ok, %{type: :regular, size: ^expected_bytes}} -> :ok
      _invalid -> {:error, :io}
    end
  end

  defp commit(stage_path, target_path, :existing) do
    case File.rename(stage_path, target_path) do
      :ok -> :ok
      {:error, _reason} -> {:error, :atomic_commit_failed}
    end
  end

  defp commit(stage_path, target_path, :missing) do
    case File.ln(stage_path, target_path) do
      :ok -> :ok
      {:error, :eexist} -> {:error, :expected_missing}
      {:error, _reason} -> {:error, :atomic_commit_failed}
    end
  end

  defp finish_creation_stage(_stage_path, :existing, _options), do: :ok

  defp finish_creation_stage(stage_path, :missing, options) do
    with :ok <- checkpoint(options, :creation_unlink),
         :ok <- File.rm(stage_path) do
      :ok
    else
      {:error, _reason} -> {:error, :durability_unknown}
    end
  end

  defp confirm(root, key, limits, request) do
    with {:ok, _resolved, observation} <- observe(root, limits, request.path),
         true <- observation.content == request.content,
         {:ok, revision} <-
           RevisionAlgorithm.calculate(key, request.path, observation.stat, observation.digest) do
      {:ok, revision}
    else
      _uncertain -> {:error, :durability_unknown}
    end
  end

  defp unique_stage(target_path),
    do: unique_stage(Elixir.Path.dirname(target_path), @stage_attempts)

  defp unique_stage(_parent, 0), do: {:error, :io}

  defp unique_stage(parent, attempts) do
    name = ".synapse-stage-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    stage_path = Elixir.Path.join(parent, name)

    if File.exists?(stage_path),
      do: unique_stage(parent, attempts - 1),
      else: {:ok, stage_path}
  end

  defp cleanup_stage(stage_path), do: cleanup_stage(stage_path, 3)

  defp cleanup_stage(_stage_path, 0), do: :error

  defp cleanup_stage(stage_path, attempts) do
    case File.rm(stage_path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} -> cleanup_stage(stage_path, attempts - 1)
    end
  end

  defp start_cleanup_guard(stage_path, owner) do
    reference = make_ref()

    guard =
      spawn(fn ->
        owner_monitor = Process.monitor(owner)

        receive do
          {:cleanup_stage, ^reference, caller} ->
            result = cleanup_stage(stage_path)
            send(caller, {:stage_cleaned, reference, result})
            Process.demonitor(owner_monitor, [:flush])

          {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
            cleanup_stage(stage_path)
        end
      end)

    {guard, reference}
  end

  defp cleanup_with_guard({guard, reference}, stage_path) do
    guard_monitor = Process.monitor(guard)
    send(guard, {:cleanup_stage, reference, self()})

    receive do
      {:stage_cleaned, ^reference, result} ->
        Process.demonitor(guard_monitor, [:flush])
        result

      {:DOWN, ^guard_monitor, :process, ^guard, _reason} ->
        cleanup_stage(stage_path)
    after
      5_000 ->
        Process.demonitor(guard_monitor, [:flush])
        Process.exit(guard, :kill)
        cleanup_stage(stage_path)
    end
  end

  defp run_with_stage_cleanup(cleanup_guard, stage_path, options, operation) do
    result = operation.()

    case stage_cleanup_result(cleanup_guard, stage_path, options) do
      :ok -> result
      :error -> {:error, :durability_unknown, :unknown}
    end
  rescue
    exception ->
      case stage_cleanup_result(cleanup_guard, stage_path, options) do
        :ok -> reraise exception, __STACKTRACE__
        :error -> {:error, :durability_unknown, :unknown}
      end
  catch
    kind, reason ->
      case stage_cleanup_result(cleanup_guard, stage_path, options) do
        :ok -> :erlang.raise(kind, reason, __STACKTRACE__)
        :error -> {:error, :durability_unknown, :unknown}
      end
  end

  defp stage_cleanup_result(cleanup_guard, stage_path, options) do
    result = cleanup_with_guard(cleanup_guard, stage_path)
    if Keyword.get(options, :fail_cleanup), do: :error, else: result
  end

  defp checkpoint(options, stage) do
    cond do
      Keyword.get(options, :raise_at) == stage ->
        raise "injected atomic writer failure"

      Keyword.get(options, :fail_at) == stage ->
        {:error, if(stage == :commit, do: :atomic_commit_failed, else: :io)}

      match?({^stage, _pid}, Keyword.get(options, :test_control)) ->
        {^stage, owner} = Keyword.fetch!(options, :test_control)
        reference = make_ref()
        send(owner, {:atomic_writer_checkpoint, stage, self(), reference})

        receive do
          {:continue_atomic_writer, ^reference} -> :ok
        after
          5_000 -> {:error, :io}
        end

      true ->
        :ok
    end
  end

  defp internal_context do
    %OperationContext{
      operation_id: "mutation-observation",
      access: %Access{read: true, write: true, exec: false},
      cancel_ref: nil,
      deadline: :infinity,
      activity_sink: nil
    }
  end
end
