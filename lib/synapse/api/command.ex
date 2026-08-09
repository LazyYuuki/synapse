defmodule Synapse.API.Command do
  @moduledoc false

  alias Synapse.API.Policy
  alias Synapse.Tool.Validation

  @type payload ::
          Synapse.API.Command.Start.t()
          | Synapse.API.Command.Cancel.t()
          | Synapse.API.Command.Subscribe.t()
          | Synapse.API.Command.Ping.t()
  @type t :: {String.t(), payload()}

  @spec new(String.t(), payload(), struct()) :: {:ok, t()} | {:error, term()}
  def new(request_id, command, config) do
    with true <- Policy.valid?(config) or {:error, {:config, :must_be_valid}},
         true <-
           Validation.identifier?(request_id, config.max_request_id_bytes) or
             {:error, {:request_id, :must_be_bounded_identifier}},
         true <- valid_command?(command, config) or {:error, {:command, :must_be_valid}} do
      {:ok, {request_id, command}}
    end
  end

  defp valid_command?(%Synapse.API.Command.Start{} = command, config),
    do: Synapse.API.Command.Start.valid?(command, config)

  defp valid_command?(%Synapse.API.Command.Cancel{} = command, config),
    do: Synapse.API.Command.Cancel.valid?(command, config)

  defp valid_command?(%Synapse.API.Command.Subscribe{} = command, config),
    do: Synapse.API.Command.Subscribe.valid?(command, config)

  defp valid_command?(%Synapse.API.Command.Ping{} = command, config),
    do: Synapse.API.Command.Ping.valid?(command, config)

  defp valid_command?(_command, _config), do: false
end

defmodule Synapse.API.Command.Start do
  @moduledoc false

  alias Synapse.Agent.ContextWindow
  alias Synapse.API.Policy
  alias Synapse.Budget
  alias Synapse.Run.Request
  alias Synapse.Tool.Validation

  @max_cwd_bytes 4_096
  @max_input_tokens ContextWindow.max_input_tokens()
  @required_fields [:prompt, :cwd, :model, :budget]
  @allowed_fields @required_fields ++ [:conversation]

  @enforce_keys @required_fields
  defstruct @required_fields ++ [conversation: []]

  @type t :: %__MODULE__{
          prompt: String.t(),
          conversation: [Synapse.Run.Request.conversation_message()],
          cwd: String.t(),
          model: String.t(),
          budget: Synapse.Budget.t()
        }

  @spec new(keyword() | map(), struct()) :: {:ok, t()} | {:error, term()}
  def new(attrs, config) do
    with true <- Policy.valid?(config) or {:error, {:config, :must_be_valid}},
         {:ok, attrs} <- Validation.attributes(attrs, @allowed_fields),
         {:ok, conversation} <- normalize_conversation(Map.get(attrs, :conversation, [])),
         true <-
           Validation.bounded_non_empty_string?(attrs[:prompt], config.max_prompt_bytes) or
             {:error, {:prompt, :must_be_bounded_non_empty_string}},
         :ok <- admit_context(conversation, attrs[:prompt], config),
         true <- valid_cwd?(attrs[:cwd]) or {:error, {:cwd, :must_be_absolute_path}},
         true <-
           attrs[:model] in config.model_allowlist or {:error, {:model, :must_be_allowlisted}},
         true <-
           budget_within_policy?(attrs[:budget], config.budget) or
             {:error, {:budget, :must_be_lowered_budget}} do
      {:ok,
       %__MODULE__{
         prompt: attrs.prompt,
         conversation: conversation,
         cwd: attrs.cwd,
         model: attrs.model,
         budget: attrs.budget
       }}
    end
  end

  @spec valid?(term(), struct()) :: boolean()
  def valid?(%__MODULE__{} = command, config),
    do: match?({:ok, %__MODULE__{}}, new(Map.from_struct(command), config))

  def valid?(_command, _config), do: false

  defp normalize_conversation(conversation) do
    case Request.normalize_conversation(conversation) do
      {:ok, conversation} ->
        {:ok, conversation}

      {:error, _reason} ->
        {:error, {:conversation, :must_be_bounded_complete_user_assistant_pairs}}
    end
  end

  defp admit_context(conversation, prompt, config) do
    case ContextWindow.estimate_tokens(conversation, prompt, config.fixed_input_tokens) do
      {:ok, tokens} when tokens <= config.max_input_tokens ->
        :ok

      {:ok, tokens} when tokens > @max_input_tokens ->
        {:error, {:context_window, :token_limit_exceeded}}

      {:ok, _tokens} ->
        {:error, {:context_window, :configured_limit_exceeded}}

      {:error, _reason} ->
        {:error, {:context_window, :must_be_estimable}}
    end
  end

  defp valid_cwd?(cwd),
    do:
      is_binary(cwd) and byte_size(cwd) <= @max_cwd_bytes and String.valid?(cwd) and
        String.trim(cwd) != "" and :binary.match(cwd, <<0>>) == :nomatch and
        Path.type(cwd) == :absolute

  defp budget_within_policy?(%Budget{} = budget, %Budget{} = server) do
    Budget.valid?(budget) and
      Enum.all?(Map.from_struct(budget), fn {field, value} ->
        value <= Map.fetch!(server, field)
      end)
  end

  defp budget_within_policy?(_budget, _server), do: false
end

defmodule Synapse.API.Command.Cancel do
  @moduledoc false

  alias Synapse.API.Policy
  alias Synapse.Tool.Validation

  @allowed_fields [:run_id]

  @enforce_keys [:run_id]
  defstruct @enforce_keys

  @type t :: %__MODULE__{run_id: String.t()}

  @spec new(keyword() | map(), struct()) :: {:ok, t()} | {:error, term()}
  def new(attrs, config) do
    with true <- Policy.valid?(config) or {:error, {:config, :must_be_valid}},
         {:ok, attrs} <- Validation.attributes(attrs, @allowed_fields),
         true <- valid_run_id?(attrs[:run_id], config) or {:error, {:run_id, :must_be_valid}} do
      {:ok, %__MODULE__{run_id: attrs.run_id}}
    end
  end

  @spec valid?(term(), struct()) :: boolean()
  def valid?(%__MODULE__{} = command, config),
    do: match?({:ok, %__MODULE__{}}, new(Map.from_struct(command), config))

  def valid?(_command, _config), do: false

  @spec valid_run_id?(term(), struct()) :: boolean()
  def valid_run_id?(<<"run_", token::binary-size(22)>> = run_id, config) do
    if Policy.valid?(config) do
      byte_size(run_id) <= config.max_run_id_bytes and canonical_token?(token)
    else
      false
    end
  end

  def valid_run_id?(_run_id, _config), do: false

  defp canonical_token?(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, bytes} when byte_size(bytes) == 16 ->
        Base.url_encode64(bytes, padding: false) == token

      _invalid ->
        false
    end
  end
end

defmodule Synapse.API.Command.Subscribe do
  @moduledoc false

  alias Synapse.API.Command.Cancel
  alias Synapse.API.Policy
  alias Synapse.Tool.Validation

  @allowed_fields [:run_id, :after_seq]

  @enforce_keys [:run_id, :after_seq]
  defstruct @enforce_keys

  @type t :: %__MODULE__{run_id: String.t(), after_seq: non_neg_integer() | nil}

  @spec new(keyword() | map(), struct()) :: {:ok, t()} | {:error, term()}
  def new(attrs, config) do
    with true <- Policy.valid?(config) or {:error, {:config, :must_be_valid}},
         {:ok, attrs} <- Validation.attributes(attrs, @allowed_fields),
         true <-
           Cancel.valid_run_id?(attrs[:run_id], config) or
             {:error, {:run_id, :must_be_valid}},
         true <- valid_cursor?(attrs[:after_seq]) or {:error, {:after_seq, :must_be_cursor}} do
      {:ok, %__MODULE__{run_id: attrs.run_id, after_seq: attrs.after_seq}}
    end
  end

  @spec valid?(term(), struct()) :: boolean()
  def valid?(%__MODULE__{} = command, config),
    do: match?({:ok, %__MODULE__{}}, new(Map.from_struct(command), config))

  def valid?(_command, _config), do: false

  defp valid_cursor?(nil), do: true
  defp valid_cursor?(cursor), do: Validation.int64?(cursor) and cursor >= 0
end

defmodule Synapse.API.Command.Ping do
  @moduledoc false

  alias Synapse.API.Policy
  alias Synapse.Tool.Validation

  defstruct []

  @type t :: %__MODULE__{}

  @spec new(keyword() | map(), struct()) :: {:ok, t()} | {:error, term()}
  def new(attrs, config) do
    with true <- Policy.valid?(config) or {:error, {:config, :must_be_valid}},
         {:ok, %{}} <- Validation.attributes(attrs, []) do
      {:ok, %__MODULE__{}}
    end
  end

  @spec valid?(term(), struct()) :: boolean()
  def valid?(%__MODULE__{}, config), do: Policy.valid?(config)
  def valid?(_command, _config), do: false
end

defimpl Inspect, for: Synapse.API.Command.Start do
  def inspect(_command, _options), do: "#Synapse.API.Command.Start<redacted>"
end

defimpl Inspect, for: Synapse.API.Command.Cancel do
  def inspect(_command, _options), do: "#Synapse.API.Command.Cancel<redacted>"
end

defimpl Inspect, for: Synapse.API.Command.Subscribe do
  def inspect(%{after_seq: after_seq}, _options)
      when (is_integer(after_seq) and after_seq >= 0 and
              after_seq <= 9_223_372_036_854_775_807) or is_nil(after_seq),
      do: "#Synapse.API.Command.Subscribe<after_seq=#{inspect(after_seq)} run_id=redacted>"

  def inspect(_command, _options), do: "#Synapse.API.Command.Subscribe<invalid redacted>"
end
