defimpl Inspect, for: Synapse.Tool.Call do
  def inspect(_call, _options),
    do: "#Synapse.Tool.Call<name=redacted call_id=redacted arguments=redacted>"
end

defimpl Inspect, for: Synapse.Tool.Result do
  def inspect(result, _options) do
    "#Synapse.Tool.Result<status=#{inspect(result.status)} call_id=redacted content=redacted metadata=redacted>"
  end
end

defimpl Inspect, for: Synapse.Tool.Spec do
  def inspect(spec, _options) do
    "#Synapse.Tool.Spec<name=#{inspect(spec.name)} capability=#{inspect(spec.capability)} effect=#{inspect(spec.effect)} parameters=redacted>"
  end
end

defimpl Inspect, for: Synapse.Tool.Context do
  def inspect(_context, _options), do: "#Synapse.Tool.Context<redacted>"
end
