defmodule Mix.Tasks.Synapse.Server do
  @shortdoc "Starts the loopback-only Synapse WebSocket API"
  @moduledoc """
  Starts the opt-in local Synapse API in the foreground.

      mix synapse.server

  Configuration comes only from the directory in which the task starts,
  `Application.get_env(:synapse, :api)`, `SYNAPSE_API_PORT`, `SYNAPSE_MODEL`, and
  `SYNAPSE_MAX_OUTPUT_BYTES`. The captured launch directory becomes the browser's
  initial Workspace path. The task accepts no run, workspace, credential, model,
  port, or bind arguments. Provider credentials remain a request-time Provider
  concern.

  On readiness the task prints the exact health and WebSocket URLs, then keeps the
  application in the foreground. See the [local API guide](api.html) for protocol,
  lifecycle, local-process access, and server-user execution limitations.
  """

  use Mix.Task

  @requirements ["app.config"]

  @impl true
  def run([]) do
    if started?(:synapse), do: Mix.raise("Synapse application is already started")

    with {:ok, launch_cwd} <- File.cwd(),
         {:ok, attrs} <-
           enabled_attributes(Application.get_env(:synapse, :api, []), launch_cwd),
         {:ok, config} <- Synapse.API.Config.load(attrs) do
      start_server(config)
    else
      _invalid -> Mix.raise("Invalid Synapse API configuration")
    end
  end

  def run(_arguments), do: Mix.raise("synapse.server accepts no arguments")

  defp enabled_attributes(attrs, launch_cwd) when is_list(attrs) do
    if Keyword.keyword?(attrs) do
      {:ok, attrs |> Keyword.put(:enabled, true) |> Keyword.put(:launch_cwd, launch_cwd)}
    else
      :error
    end
  end

  defp enabled_attributes(attrs, launch_cwd) when is_map(attrs) and not is_struct(attrs),
    do: {:ok, attrs |> Map.put(:enabled, true) |> Map.put(:launch_cwd, launch_cwd)}

  defp enabled_attributes(_attrs, _launch_cwd), do: :error

  defp start_server(config) do
    previous = Application.get_env(:synapse, :api, :undefined)
    Application.put_env(:synapse, :api, config, persistent: true)

    try do
      Mix.Task.run("app.start")
      {:ok, listener} = Synapse.API.Supervisor.listener()
      {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(listener)
      Mix.shell().info("Health: http://127.0.0.1:#{port}/health")
      Mix.shell().info("WebSocket: ws://127.0.0.1:#{port}/v1/socket")
      System.no_halt(true)
    rescue
      _exception -> rollback(previous)
    catch
      _kind, _reason -> rollback(previous)
    end
  end

  defp rollback(previous) do
    if started?(:synapse), do: Application.stop(:synapse)
    restore(previous)
    Mix.raise("Synapse API failed to start")
  end

  defp restore(:undefined), do: Application.delete_env(:synapse, :api, persistent: true)
  defp restore(previous), do: Application.put_env(:synapse, :api, previous, persistent: true)

  defp started?(application) do
    Enum.any?(Application.started_applications(), fn {name, _description, _version} ->
      name == application
    end)
  end
end
