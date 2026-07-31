# Internal secret-minimizing child environment and private runtime directories.
defmodule Synapse.Workspace.ProcessEnvironment do
  @moduledoc false

  alias Synapse.Workspace.{Limits, Validation}

  @attempts 8
  @allowed_names ~w(PATH HOME TMPDIR LANG TERM GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM SHLVL)

  @enforce_keys [:root, :home, :tmp, :path, :guard, :guard_reference]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  @spec open(Limits.t(), pid()) :: {:ok, t()} | {:error, :io}
  def open(limits, owner) do
    with {:ok, root} <- unique_root(@attempts),
         :ok <- make_private_tree(root) do
      home = Elixir.Path.join(root, "home")
      tmp = Elixir.Path.join(root, "tmp")
      path = trusted_path(limits)

      if Enum.all?([root, home, tmp, path], &valid_value?(&1, limits)) do
        reference = make_ref()
        cleanup_delay_ms = 2 * limits.kill_grace_ms + 500
        guard = spawn(fn -> cleanup_guard(root, owner, reference, cleanup_delay_ms) end)

        {:ok,
         %__MODULE__{
           root: root,
           home: home,
           tmp: tmp,
           path: path,
           guard: guard,
           guard_reference: reference
         }}
      else
        cleanup(root, 0)
        {:error, :io}
      end
    else
      _failure -> {:error, :io}
    end
  end

  @spec build(t(), Limits.t()) :: {:ok, keyword(String.t())} | {:error, :io}
  def build(environment, limits) do
    inherited = System.get_env()

    allowed = [
      {"PATH", environment.path},
      {"HOME", environment.home},
      {"TMPDIR", environment.tmp},
      {"LANG", "C.UTF-8"},
      {"TERM", "dumb"},
      {"GIT_CONFIG_GLOBAL", "/dev/null"},
      {"GIT_CONFIG_NOSYSTEM", "1"},
      {"SHLVL", "0"}
    ]

    with true <- map_size(inherited) + length(allowed) <= limits.max_environment_entries,
         inherited_names <- inherited |> Map.keys() |> Enum.sort(),
         true <- Enum.all?(inherited_names, &valid_name?(&1, limits)),
         true <-
           Enum.all?(allowed, fn {name, value} ->
             valid_name?(name, limits) and valid_value?(value, limits)
           end) do
      unsets = Enum.map(inherited_names, &{&1, nil})
      {:ok, unsets ++ allowed}
    else
      false -> {:error, :io}
    end
  end

  @spec allowed_names() :: [String.t()]
  def allowed_names, do: @allowed_names

  @spec close(t(), non_neg_integer()) :: :ok | :error
  def close(environment, delay_ms \\ 0) do
    monitor = Process.monitor(environment.guard)

    send(
      environment.guard,
      {:cleanup_process_environment, environment.guard_reference, self(), delay_ms}
    )

    receive do
      {:process_environment_cleaned, reference, result}
      when reference == environment.guard_reference ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, _guard, _reason} ->
        cleanup(environment.root, delay_ms)
    after
      max(delay_ms + 1_000, 5_000) ->
        Process.demonitor(monitor, [:flush])
        Process.exit(environment.guard, :kill)
        cleanup(environment.root, 0)
    end
  end

  defp unique_root(0), do: {:error, :io}

  defp unique_root(attempts) do
    name =
      "synapse-workspace-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    root = Elixir.Path.join(System.tmp_dir!(), name)

    case File.mkdir(root) do
      :ok -> {:ok, root}
      {:error, :eexist} -> unique_root(attempts - 1)
      {:error, _reason} -> {:error, :io}
    end
  end

  defp make_private_tree(root) do
    with :ok <- File.chmod(root, 0o700),
         :ok <- File.mkdir(Elixir.Path.join(root, "home")),
         :ok <- File.chmod(Elixir.Path.join(root, "home"), 0o700),
         :ok <- File.mkdir(Elixir.Path.join(root, "tmp")),
         :ok <- File.chmod(Elixir.Path.join(root, "tmp"), 0o700) do
      :ok
    else
      _failure ->
        File.rm_rf(root)
        {:error, :io}
    end
  end

  defp trusted_path(limits) do
    case System.get_env("PATH") do
      path when is_binary(path) and path != "" ->
        if valid_value?(path, limits), do: path, else: "/usr/bin:/bin:/usr/sbin:/sbin"

      _missing_or_invalid ->
        "/usr/bin:/bin:/usr/sbin:/sbin"
    end
  end

  defp valid_name?(name, limits) do
    Validation.bounded_string?(name, limits.max_environment_name_bytes, false) and
      :binary.match(name, <<0>>) == :nomatch and :binary.match(name, "=") == :nomatch
  end

  defp valid_value?(value, limits) do
    Validation.bounded_string?(value, limits.max_environment_value_bytes) and
      :binary.match(value, <<0>>) == :nomatch
  end

  defp cleanup_guard(root, owner, reference, cleanup_delay_ms) do
    owner_monitor = Process.monitor(owner)

    receive do
      {:cleanup_process_environment, ^reference, caller, delay_ms} ->
        result = cleanup(root, delay_ms)
        send(caller, {:process_environment_cleaned, reference, result})
        Process.demonitor(owner_monitor, [:flush])

      {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
        cleanup(root, cleanup_delay_ms)
    end
  end

  defp cleanup(root, delay_ms), do: cleanup(root, delay_ms, 3)

  defp cleanup(_root, _delay_ms, 0), do: :error

  defp cleanup(root, delay_ms, attempts) do
    if delay_ms > 0, do: Process.sleep(delay_ms)

    case File.rm_rf(root) do
      {:ok, _entries} -> :ok
      {:error, _reason, _path} -> cleanup(root, 0, attempts - 1)
    end
  end
end
