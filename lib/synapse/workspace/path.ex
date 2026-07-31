# Internal host-path implementation for the cooperative macOS/APFS MVP boundary.
defmodule Synapse.Workspace.Path do
  @moduledoc false

  alias Elixir.Path, as: HostPath
  alias Synapse.Workspace.{Resolved, Root}

  @type lexical_reason ::
          :empty_path
          | :absolute_path
          | :nul_byte
          | :invalid_utf8
          | :empty_component
          | :dot_component
          | :path_traversal
          | :path_too_long

  @type resolution_reason ::
          lexical_reason()
          | :invalid_root
          | :not_found
          | :symlink
          | :mount_crossing
          | :multiple_hard_links
          | :not_regular_file
          | :io

  @spec normalize(term(), pos_integer(), keyword()) ::
          {:ok, String.t()} | {:error, lexical_reason()}
  def normalize(path, max_bytes, options \\ []) do
    allow_dot? = Keyword.get(options, :allow_dot, false)

    cond do
      not is_binary(path) -> {:error, :invalid_utf8}
      byte_size(path) > max_bytes -> {:error, :path_too_long}
      not String.valid?(path) -> {:error, :invalid_utf8}
      path == "" -> {:error, :empty_path}
      :binary.match(path, <<0>>) != :nomatch -> {:error, :nul_byte}
      HostPath.type(path) != :relative -> {:error, :absolute_path}
      path == "." and allow_dot? -> {:ok, "."}
      true -> normalize_components(path)
    end
  end

  @spec resolve(Root.t(), term(), pos_integer(), :file | :directory, keyword()) ::
          {:ok, Resolved.t()} | {:error, resolution_reason()}
  def resolve(%Root{} = root, path, max_bytes, expected_type, options \\ []) do
    allow_missing? = Keyword.get(options, :allow_missing, false)
    before_revalidate = Keyword.get(options, :before_revalidate, fn -> :ok end)
    allow_dot? = expected_type == :directory

    with {:ok, relative} <- normalize(path, max_bytes, allow_dot: allow_dot?),
         :ok <- Root.validate(root),
         {:ok, resolved, observations} <- walk(root, relative, expected_type, allow_missing?),
         :ok <- before_revalidate.(),
         :ok <- revalidate(observations),
         :ok <- Root.validate(root) do
      {:ok, resolved}
    end
  end

  defp normalize_components(path) do
    components = :binary.split(path, "/", [:global])

    cond do
      Enum.any?(components, &(&1 == "")) -> {:error, :empty_component}
      Enum.any?(components, &(&1 == ".")) -> {:error, :dot_component}
      Enum.any?(components, &(&1 == "..")) -> {:error, :path_traversal}
      true -> {:ok, Enum.join(components, "/")}
    end
  end

  defp walk(root, ".", :directory, _allow_missing?) do
    with {:ok, stat} <- File.lstat(root.canonical_path),
         :ok <- validate_type(stat, :directory, root.device) do
      {:ok,
       %Resolved{
         relative: ".",
         absolute: root.canonical_path,
         type: :directory,
         stat: stat
       }, [{root.canonical_path, identity(stat)}]}
    end
  end

  defp walk(root, relative, expected_type, allow_missing?) do
    components = :binary.split(relative, "/", [:global])

    walk_components(
      root,
      root.canonical_path,
      components,
      relative,
      expected_type,
      allow_missing?,
      []
    )
  end

  defp walk_components(
         root,
         current,
         [component | rest],
         relative,
         expected_type,
         allow_missing?,
         observations
       ) do
    candidate = HostPath.join(current, component)
    final? = rest == []

    case File.lstat(candidate) do
      {:ok, %File.Stat{type: :symlink}} ->
        {:error, :symlink}

      {:ok, stat} when final? ->
        with :ok <- validate_type(stat, expected_type, root.device) do
          {:ok,
           %Resolved{
             relative: relative,
             absolute: candidate,
             type: expected_type,
             stat: stat
           }, [{candidate, identity(stat)} | observations]}
        end

      {:ok, stat} ->
        with :ok <- validate_type(stat, :directory, root.device) do
          walk_components(
            root,
            candidate,
            rest,
            relative,
            expected_type,
            allow_missing?,
            [{candidate, identity(stat)} | observations]
          )
        end

      {:error, :enoent} when final? and allow_missing? ->
        {:ok,
         %Resolved{
           relative: relative,
           absolute: candidate,
           type: :missing,
           stat: nil
         }, [{candidate, :missing} | observations]}

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, _reason} ->
        {:error, :io}
    end
  end

  defp revalidate(observations) do
    observations
    |> Enum.reverse()
    |> Enum.reduce_while(:ok, fn {path, expected_identity}, :ok ->
      case {expected_identity, File.lstat(path)} do
        {:missing, {:error, :enoent}} ->
          {:cont, :ok}

        {:missing, {:ok, %File.Stat{type: :symlink}}} ->
          {:halt, {:error, :symlink}}

        {:missing, _result} ->
          {:halt, {:error, :io}}

        {_identity, {:ok, %File.Stat{type: :symlink}}} ->
          {:halt, {:error, :symlink}}

        {_identity, {:ok, stat}} ->
          if identity(stat) == expected_identity,
            do: {:cont, :ok},
            else: {:halt, {:error, :io}}

        {_identity, {:error, _reason}} ->
          {:halt, {:error, :io}}
      end
    end)
  end

  defp validate_type(%File.Stat{} = stat, expected_type, root_device) do
    cond do
      stat.type != host_type(expected_type) -> {:error, :not_regular_file}
      device(stat) != root_device -> {:error, :mount_crossing}
      expected_type == :file and stat.links != 1 -> {:error, :multiple_hard_links}
      true -> :ok
    end
  end

  defp device(stat), do: {stat.major_device, stat.minor_device}

  defp identity(stat),
    do: {stat.major_device, stat.minor_device, stat.inode, stat.type, stat.links}

  defp host_type(:file), do: :regular
  defp host_type(:directory), do: :directory
end

defmodule Synapse.Workspace.Root do
  @moduledoc false

  alias Elixir.Path, as: HostPath
  alias Synapse.Workspace.Limits

  @max_root_symlinks 40

  @enforce_keys [:canonical_path, :identity, :device]
  defstruct [:canonical_path, :identity, :device]

  @type identity :: {integer(), integer(), integer(), :directory}
  @type t :: %__MODULE__{
          canonical_path: String.t(),
          identity: identity(),
          device: {integer(), integer()}
        }

  @spec open(String.t(), pos_integer() | Limits.t()) ::
          {:ok, t()} | {:error, :invalid_root | :unsupported_filesystem}
  def open(root, %Limits{} = limits),
    do: open(root, limits.max_path_bytes, limits)

  def open(root, max_bytes) do
    open(root, max_bytes, Limits.default())
  end

  defp open(root, max_bytes, limits) do
    with true <- is_binary(root) and String.valid?(root) and byte_size(root) <= max_bytes,
         true <- :binary.match(root, <<0>>) == :nomatch,
         {:ok, canonical_path} <- resolve_root(root, max_bytes, 0),
         {:ok, before_stat} <- File.lstat(canonical_path),
         true <- before_stat.type == :directory,
         :ok <- open_readable_directory(canonical_path),
         {:ok, after_stat} <- File.lstat(canonical_path),
         true <- identity(before_stat) == identity(after_stat),
         :ok <- Synapse.Workspace.Platform.ensure_filesystem(canonical_path, limits) do
      {:ok,
       %__MODULE__{
         canonical_path: canonical_path,
         identity: identity(after_stat),
         device: device(after_stat)
       }}
    else
      {:error, :unsupported_filesystem} -> {:error, :unsupported_filesystem}
      _invalid -> {:error, :invalid_root}
    end
  end

  defp open_readable_directory(path) do
    case :file.open(path, [:read, :raw, :binary, :directory]) do
      {:ok, descriptor} -> :file.close(descriptor)
      {:error, _reason} -> {:error, :invalid_root}
    end
  end

  @spec validate(t()) :: :ok | {:error, :invalid_root}
  def validate(%__MODULE__{} = root) do
    case File.lstat(root.canonical_path) do
      {:ok, stat} ->
        if identity(stat) == root.identity, do: :ok, else: {:error, :invalid_root}

      {:error, _reason} ->
        {:error, :invalid_root}
    end
  end

  defp resolve_root(path, max_bytes, symlink_count) when symlink_count <= @max_root_symlinks do
    with {:ok, components} <- root_components(path) do
      walk_root("/", components, max_bytes, symlink_count)
    end
  end

  defp resolve_root(_path, _max_bytes, _symlink_count), do: {:error, :invalid_root}

  defp walk_root(_current, _components, _max_bytes, symlink_count)
       when symlink_count > @max_root_symlinks,
       do: {:error, :invalid_root}

  defp walk_root(current, [], _max_bytes, _symlink_count), do: {:ok, current}

  defp walk_root(current, [component | rest], max_bytes, symlink_count)
       when component in ["", "."],
       do: walk_root(current, rest, max_bytes, symlink_count)

  defp walk_root(current, [".." | rest], max_bytes, symlink_count),
    do: walk_root(HostPath.dirname(current), rest, max_bytes, symlink_count)

  defp walk_root(current, [component | rest], max_bytes, symlink_count) do
    candidate = HostPath.join(current, component)

    if byte_size(candidate) > max_bytes do
      {:error, :invalid_root}
    else
      case File.lstat(candidate) do
        {:ok, %File.Stat{type: :symlink}} ->
          with {:ok, target} <- File.read_link(candidate),
               true <- valid_link_target?(target),
               {target_root, target_components} <- root_link_target(current, target, rest) do
            walk_root(target_root, target_components, max_bytes, symlink_count + 1)
          else
            _invalid -> {:error, :invalid_root}
          end

        {:ok, %File.Stat{type: :directory}} ->
          walk_root(candidate, rest, max_bytes, symlink_count)

        {:ok, _stat} when rest == [] ->
          {:ok, candidate}

        {:ok, _stat} ->
          {:error, :invalid_root}

        {:error, _reason} ->
          {:error, :invalid_root}
      end
    end
  end

  defp root_components(path) do
    if HostPath.type(path) == :absolute do
      {:ok, components(path)}
    else
      case File.cwd() do
        {:ok, cwd} -> {:ok, components(cwd) ++ components(path)}
        {:error, _reason} -> {:error, :invalid_root}
      end
    end
  end

  defp root_link_target(current, target, rest) do
    if HostPath.type(target) == :absolute,
      do: {"/", components(target) ++ rest},
      else: {current, components(target) ++ rest}
  end

  defp components(path),
    do: path |> :binary.split("/", [:global]) |> Enum.reject(&(&1 == ""))

  defp valid_link_target?(target),
    do: is_binary(target) and String.valid?(target) and :binary.match(target, <<0>>) == :nomatch

  defp identity(stat),
    do: {stat.major_device, stat.minor_device, stat.inode, stat.type}

  defp device(stat), do: {stat.major_device, stat.minor_device}
end

defmodule Synapse.Workspace.Platform do
  @moduledoc false

  alias Synapse.Workspace.{DiscardOutput, Limits, Validation}

  @spec supported?() :: boolean()
  def supported?,
    do: supported?(:os.type(), :erlang.system_info(:system_architecture), :os.version())

  @spec supported?({atom(), atom()}, binary() | charlist(), {integer(), integer(), integer()}) ::
          boolean()
  def supported?({:unix, :darwin}, architecture, version) do
    arm64? = architecture |> to_string() |> String.starts_with?(["aarch64-", "arm64-"])
    arm64? and supported_darwin_version?(version)
  end

  def supported?(_os_type, _architecture, _version), do: false

  @spec ensure_filesystem(String.t(), Limits.t()) :: :ok | {:error, :unsupported_filesystem}
  def ensure_filesystem(path, limits) do
    with {:ok, environment} <- cleared_environment(limits),
         {%DiscardOutput{}, 0} <-
           MuonTrap.cmd(
             "/bin/df",
             ["-t", "apfs", path],
             env: environment,
             timeout: 1_000,
             delay_to_sigkill: limits.kill_grace_ms,
             capture_stderr_only: true,
             into: %DiscardOutput{}
           ) do
      :ok
    else
      _unsupported -> {:error, :unsupported_filesystem}
    end
  rescue
    _exception -> {:error, :unsupported_filesystem}
  catch
    _kind, _reason -> {:error, :unsupported_filesystem}
  end

  defp supported_darwin_version?({major, minor, _patch}),
    do: major > 24 or (major == 24 and minor >= 6)

  defp supported_darwin_version?(_version), do: false

  defp cleared_environment(limits) do
    environment = System.get_env()

    if map_size(environment) <= limits.max_environment_entries and
         Enum.all?(Map.keys(environment), fn name ->
           Validation.bounded_string?(name, limits.max_environment_name_bytes, false) and
             :binary.match(name, <<0>>) == :nomatch
         end) do
      {:ok, Enum.map(Map.keys(environment), &{&1, nil})}
    else
      {:error, :unsupported_environment}
    end
  end
end
