defimpl Inspect, for: Synapse.Provider.Request do
  def inspect(_request, _options), do: "#Synapse.Provider.Request<redacted>"
end

defimpl Inspect, for: Synapse.Provider.Response do
  def inspect(response, _options),
    do: "#Synapse.Provider.Response<status=#{inspect(response.status)} redacted>"
end

defimpl Inspect, for: Synapse.Provider.Error do
  def inspect(error, _options),
    do: "#Synapse.Provider.Error<kind=#{inspect(error.kind)} redacted>"
end

defimpl Inspect, for: Synapse.Provider.StreamContext do
  def inspect(_context, _options), do: "#Synapse.Provider.StreamContext<redacted>"
end

defimpl Inspect, for: Synapse.Provider.OutputItem.Message do
  def inspect(_message, _options), do: "#Synapse.Provider.OutputItem.Message<redacted>"
end

defimpl Inspect, for: Synapse.Provider.OutputItem.FunctionCall do
  def inspect(_call, _options),
    do: "#Synapse.Provider.OutputItem.FunctionCall<redacted>"
end

defimpl Inspect, for: Synapse.Provider.Event.MessageStarted do
  def inspect(_event, _options), do: "#Synapse.Provider.Event.MessageStarted<redacted>"
end

defimpl Inspect, for: Synapse.Provider.Event.TextDelta do
  def inspect(_event, _options), do: "#Synapse.Provider.Event.TextDelta<redacted>"
end

defimpl Inspect, for: Synapse.Provider.Event.ToolCallStarted do
  def inspect(_event, _options), do: "#Synapse.Provider.Event.ToolCallStarted<redacted>"
end

defimpl Inspect, for: Synapse.Provider.Event.ToolCallDelta do
  def inspect(_event, _options), do: "#Synapse.Provider.Event.ToolCallDelta<redacted>"
end

defimpl Inspect, for: Synapse.Provider.Event.ToolCallCompleted do
  def inspect(_event, _options), do: "#Synapse.Provider.Event.ToolCallCompleted<redacted>"
end

defimpl Inspect, for: Synapse.Provider.Event.MessageCompleted do
  def inspect(_event, _options), do: "#Synapse.Provider.Event.MessageCompleted<redacted>"
end

defimpl Inspect, for: Synapse.Provider.Event.Diagnostic do
  def inspect(_event, _options), do: "#Synapse.Provider.Event.Diagnostic<redacted>"
end

defimpl Inspect, for: Synapse.Provider.SSEEvent do
  def inspect(_event, _options), do: "#Synapse.Provider.SSEEvent<redacted>"
end

defimpl Inspect, for: Synapse.Provider.SSEDecoder do
  def inspect(_decoder, _options), do: "#Synapse.Provider.SSEDecoder<redacted>"
end

defimpl Inspect, for: Synapse.Provider.ResponsesStream do
  def inspect(_stream, _options), do: "#Synapse.Provider.ResponsesStream<redacted>"
end
