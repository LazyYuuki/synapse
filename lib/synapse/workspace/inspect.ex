defimpl Inspect, for: Synapse.Workspace.OpenRequest do
  def inspect(_value, _options), do: "#Synapse.Workspace.OpenRequest<redacted>"
end

defimpl Inspect, for: Synapse.Workspace.ReadLine do
  def inspect(_value, _options), do: "#Synapse.Workspace.ReadLine<redacted>"
end

defimpl Inspect, for: Synapse.Workspace.ReadResult do
  def inspect(_value, _options), do: "#Synapse.Workspace.ReadResult<redacted>"
end

defimpl Inspect, for: Synapse.Workspace.WriteRequest do
  def inspect(_value, _options), do: "#Synapse.Workspace.WriteRequest<redacted>"
end

defimpl Inspect, for: Synapse.Workspace.EditRequest do
  def inspect(_value, _options), do: "#Synapse.Workspace.EditRequest<redacted>"
end

defimpl Inspect, for: Synapse.Workspace.MutationResult do
  def inspect(_value, _options), do: "#Synapse.Workspace.MutationResult<redacted>"
end

defimpl Inspect, for: Synapse.Workspace.ProcessSpec do
  def inspect(_value, _options), do: "#Synapse.Workspace.ProcessSpec<redacted>"
end

defimpl Inspect, for: Synapse.Workspace.ProcessEvent.Output do
  def inspect(_value, _options), do: "#Synapse.Workspace.ProcessEvent.Output<redacted>"
end

defimpl Inspect, for: Synapse.Workspace.ProcessResult do
  def inspect(_value, _options), do: "#Synapse.Workspace.ProcessResult<redacted>"
end

defimpl Inspect, for: Synapse.Workspace.Fake.Entry do
  def inspect(_value, _options), do: "#Synapse.Workspace.Fake.Entry<redacted>"
end

defimpl Inspect, for: Synapse.Workspace.Error do
  import Inspect.Algebra

  def inspect(error, options) do
    concat([
      "#Synapse.Workspace.Error<",
      to_doc(
        %{
          kind: error.kind,
          operation: error.operation,
          outcome: error.outcome,
          reason: error.reason
        },
        options
      ),
      ">"
    ])
  end
end

defimpl Inspect, for: Synapse.Workspace.Root do
  def inspect(_value, _options), do: "#Synapse.Workspace.Root<redacted>"
end

defimpl Inspect, for: Synapse.Workspace.Resolved do
  def inspect(_value, _options), do: "#Synapse.Workspace.Resolved<redacted>"
end

defimpl Inspect, for: Synapse.Workspace.Reader do
  def inspect(_value, _options), do: "#Synapse.Workspace.Reader<redacted>"
end

defimpl Inspect, for: Synapse.Workspace.ProcessEnvironment do
  def inspect(_value, _options), do: "#Synapse.Workspace.ProcessEnvironment<redacted>"
end
