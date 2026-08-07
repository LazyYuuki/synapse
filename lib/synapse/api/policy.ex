defmodule Synapse.API.Policy do
  @moduledoc false

  alias Synapse.API.Config
  alias Synapse.Budget
  alias Synapse.Tool.Validation

  @fields [
    :model_allowlist,
    :default_model,
    :budget,
    :max_incoming_message_bytes,
    :max_outgoing_message_bytes,
    :max_prompt_bytes,
    :max_request_id_bytes,
    :max_run_id_bytes,
    :max_json_depth,
    :max_json_object_keys,
    :max_json_array_elements,
    :max_json_nodes,
    :max_projection_text_bytes,
    :max_pull_events,
    :max_pull_bytes,
    :max_subscriptions_per_socket,
    :max_protocol_violations,
    :max_operation_id_bytes,
    :max_call_id_bytes,
    :max_tool_name_bytes
  ]

  @enforce_keys @fields
  defstruct @fields

  @maximums %{
    max_incoming_message_bytes: 2_097_152,
    max_outgoing_message_bytes: 1_048_576,
    max_prompt_bytes: 262_144,
    max_request_id_bytes: 128,
    max_run_id_bytes: 64,
    max_json_depth: 16,
    max_json_object_keys: 32,
    max_json_array_elements: 128,
    max_json_nodes: 4_096,
    max_projection_text_bytes: 64_000,
    max_pull_events: 64,
    max_pull_bytes: 1_048_576,
    max_subscriptions_per_socket: 16,
    max_protocol_violations: 8,
    max_operation_id_bytes: 256,
    max_call_id_bytes: 512,
    max_tool_name_bytes: 64
  }

  @type t :: %__MODULE__{
          model_allowlist: [String.t()],
          default_model: String.t() | nil,
          budget: Budget.t(),
          max_incoming_message_bytes: pos_integer(),
          max_outgoing_message_bytes: pos_integer(),
          max_prompt_bytes: pos_integer(),
          max_request_id_bytes: pos_integer(),
          max_run_id_bytes: pos_integer(),
          max_json_depth: pos_integer(),
          max_json_object_keys: pos_integer(),
          max_json_array_elements: pos_integer(),
          max_json_nodes: pos_integer(),
          max_projection_text_bytes: pos_integer(),
          max_pull_events: pos_integer(),
          max_pull_bytes: pos_integer(),
          max_subscriptions_per_socket: pos_integer(),
          max_protocol_violations: pos_integer(),
          max_operation_id_bytes: pos_integer(),
          max_call_id_bytes: pos_integer(),
          max_tool_name_bytes: pos_integer()
        }

  @spec from_config(Config.t()) :: {:ok, t()} | {:error, :invalid_api_policy}
  def from_config(%Config{} = config) do
    if Config.valid?(config) do
      limits = config.runtime_options.tool_limits

      {:ok,
       %__MODULE__{
         model_allowlist: config.model_allowlist,
         default_model: config.default_model,
         budget: config.budget,
         max_incoming_message_bytes: config.max_incoming_message_bytes,
         max_outgoing_message_bytes: config.max_outgoing_message_bytes,
         max_prompt_bytes: config.max_prompt_bytes,
         max_request_id_bytes: config.max_request_id_bytes,
         max_run_id_bytes: config.max_run_id_bytes,
         max_json_depth: config.max_json_depth,
         max_json_object_keys: config.max_json_object_keys,
         max_json_array_elements: config.max_json_array_elements,
         max_json_nodes: config.max_json_nodes,
         max_projection_text_bytes: config.max_projection_text_bytes,
         max_pull_events: config.max_pull_events,
         max_pull_bytes: config.max_pull_bytes,
         max_subscriptions_per_socket: config.max_subscriptions_per_socket,
         max_protocol_violations: config.max_protocol_violations,
         max_operation_id_bytes: limits.max_operation_id_bytes,
         max_call_id_bytes: limits.max_call_id_bytes,
         max_tool_name_bytes: limits.max_tool_name_bytes
       }}
    else
      {:error, :invalid_api_policy}
    end
  end

  def from_config(_config), do: {:error, :invalid_api_policy}

  @spec valid?(term()) :: boolean()
  def valid?(%Config{} = config), do: Config.valid?(config)

  def valid?(%__MODULE__{} = policy) do
    bounded_models?(policy) and Budget.valid?(policy.budget) and
      Enum.all?(@fields -- [:model_allowlist, :default_model, :budget], fn field ->
        value = Map.fetch!(policy, field)
        positive_int64?(value) and value <= Map.fetch!(@maximums, field)
      end) and policy.max_prompt_bytes <= policy.max_incoming_message_bytes and
      policy.max_request_id_bytes <= policy.max_incoming_message_bytes and
      policy.max_run_id_bytes <= policy.max_incoming_message_bytes and
      policy.max_projection_text_bytes <= policy.max_outgoing_message_bytes and
      policy.max_pull_bytes <= policy.max_outgoing_message_bytes
  rescue
    _exception -> false
  catch
    _kind, _reason -> false
  end

  def valid?(_policy), do: false

  @spec lower_budget(struct(), keyword() | map()) ::
          {:ok, Budget.t()} | {:error, term()}
  def lower_budget(%Config{} = config, attrs), do: Config.lower_budget(config, attrs)

  def lower_budget(%__MODULE__{} = policy, attrs) do
    with true <- valid?(policy) or {:error, {:policy, :must_be_valid}},
         fields <- Map.keys(Map.from_struct(policy.budget)),
         {:ok, attrs} <- Validation.attributes(attrs, fields),
         true <-
           Enum.all?(attrs, fn {field, value} ->
             is_integer(value) and value <= Map.fetch!(policy.budget, field)
           end) or {:error, {:budget, :must_not_widen_policy}},
         {:ok, budget} <- Budget.new(Map.merge(Map.from_struct(policy.budget), attrs)) do
      {:ok, budget}
    end
  end

  def lower_budget(_policy, _attrs), do: {:error, {:policy, :must_be_valid}}

  @spec max_operation_id_bytes(struct()) :: pos_integer()
  def max_operation_id_bytes(%Config{} = config),
    do: config.runtime_options.tool_limits.max_operation_id_bytes

  def max_operation_id_bytes(%__MODULE__{} = policy), do: policy.max_operation_id_bytes

  @spec max_call_id_bytes(struct()) :: pos_integer()
  def max_call_id_bytes(%Config{} = config),
    do: config.runtime_options.tool_limits.max_call_id_bytes

  def max_call_id_bytes(%__MODULE__{} = policy), do: policy.max_call_id_bytes

  @spec max_tool_name_bytes(struct()) :: pos_integer()
  def max_tool_name_bytes(%Config{} = config),
    do: config.runtime_options.tool_limits.max_tool_name_bytes

  def max_tool_name_bytes(%__MODULE__{} = policy), do: policy.max_tool_name_bytes

  defp bounded_models?(policy) do
    Validation.proper_list?(policy.model_allowlist, 128) and
      Enum.all?(policy.model_allowlist, &Validation.identifier?(&1, 256)) and
      length(policy.model_allowlist) == length(Enum.uniq(policy.model_allowlist)) and
      (is_nil(policy.default_model) or policy.default_model in policy.model_allowlist)
  end

  defp positive_int64?(value), do: Validation.int64?(value) and value > 0
end

defimpl Inspect, for: Synapse.API.Policy do
  def inspect(policy, _options) do
    if Synapse.API.Policy.valid?(policy) do
      "#Synapse.API.Policy<models=#{length(policy.model_allowlist)} redacted>"
    else
      "#Synapse.API.Policy<invalid redacted>"
    end
  end
end
