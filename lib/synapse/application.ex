defmodule Synapse.Application do
  @moduledoc """
  Starts and owns the root Synapse supervision tree.

  Ordinary startup starts exactly three permanent infrastructure children under
  `Synapse.Supervisor`: Workspace DynamicSupervisor, Task.Supervisor, and Runtime
  DynamicSupervisor. Validated opt-in API configuration appends
  `Synapse.API.Supervisor` after Runtime so reverse shutdown stops the listener and
  sessions while lower cleanup infrastructure remains available.

  The OTP application controller calls `start/2`; application code should not
  call it directly.
  """

  use Application

  @doc """
  Starts the named root supervisor for Synapse.

  The root uses `:one_for_one`, starts infrastructure in dependency order, and
  relies on reverse OTP shutdown order so Workspace cleanup remains available
  while Runtime and Agent children terminate.
  """
  @impl true
  @spec start(Application.start_type(), term()) :: Supervisor.on_start()
  def start(_type, _args) do
    case api_config(Application.get_env(:synapse, :api, [])) do
      {:ok, config} -> Synapse.Supervisor.start_link(api_config: config)
      {:error, _reason} -> {:error, :invalid_api_config}
    end
  end

  defp api_config(%Synapse.API.Config{} = config) do
    if Synapse.API.Config.valid?(config), do: {:ok, config}, else: {:error, :invalid_api_config}
  end

  defp api_config(attrs) do
    if configured_enabled?(attrs),
      do: Synapse.API.Config.load(attrs),
      else: Synapse.API.Config.new(attrs)
  end

  defp configured_enabled?(attrs) when is_list(attrs),
    do: Keyword.get(attrs, :enabled, false) == true

  defp configured_enabled?(attrs) when is_map(attrs), do: Map.get(attrs, :enabled, false) == true
  defp configured_enabled?(_attrs), do: false
end
