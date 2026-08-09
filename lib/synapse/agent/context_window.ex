defmodule Synapse.Agent.ContextWindow do
  @moduledoc """
  Conservative model-input estimation for API admission.

  Synapse has no model tokenizer or remote count endpoint, so admission estimates
  tokens as canonical Provider request JSON bytes divided by three and rounded up.
  Fixed instructions and Tool schemas are estimated once by `fixed_input_tokens/2`.
  Structured conversation plus the current prompt are estimated by
  `estimate_tokens/3`; rounding the two components separately is conservative.

  The fixed component includes the request JSON envelope and a 1,024-byte reserve
  for the selected model and local metadata. The estimate is admission policy, not
  a claim about any provider's exact tokenization.
  """

  @max_input_tokens 272_000
  @model_metadata_reserve_bytes 1_024

  @doc "Returns the application-wide maximum estimated model input."
  @spec max_input_tokens() :: 272_000
  def max_input_tokens, do: @max_input_tokens

  @doc "Estimates the fixed instructions, Tool schemas, envelope, model, and metadata."
  @spec fixed_input_tokens(String.t(), [Synapse.Provider.json_object()]) ::
          {:ok, pos_integer()} | {:error, :invalid_fixed_context}
  def fixed_input_tokens(instructions, tools)
      when is_binary(instructions) and is_list(tools) do
    if String.valid?(instructions) do
      encoded =
        JSON.encode!(%{
          "input" => [],
          "instructions" => instructions,
          "tools" => tools
        })

      fixed_bytes = byte_size(encoded) - byte_size("[]") + @model_metadata_reserve_bytes
      {:ok, tokens_for_bytes(fixed_bytes)}
    else
      {:error, :invalid_fixed_context}
    end
  rescue
    _exception -> {:error, :invalid_fixed_context}
  catch
    _kind, _reason -> {:error, :invalid_fixed_context}
  end

  def fixed_input_tokens(_instructions, _tools), do: {:error, :invalid_fixed_context}

  @doc "Estimates fixed plus structured historical and current user input tokens."
  @spec estimate_tokens(
          [Synapse.Run.Request.conversation_message()],
          String.t(),
          pos_integer()
        ) :: {:ok, pos_integer()} | {:error, :invalid_dynamic_context}
  def estimate_tokens(conversation, prompt, fixed_input_tokens)
      when is_list(conversation) and is_binary(prompt) and is_integer(fixed_input_tokens) and
             fixed_input_tokens > 0 do
    if String.valid?(prompt) do
      input_items = Enum.map(conversation, &conversation_input/1) ++ [user_input(prompt)]
      dynamic_tokens = input_items |> JSON.encode!() |> byte_size() |> tokens_for_bytes()
      {:ok, fixed_input_tokens + dynamic_tokens}
    else
      {:error, :invalid_dynamic_context}
    end
  rescue
    _exception -> {:error, :invalid_dynamic_context}
  catch
    _kind, _reason -> {:error, :invalid_dynamic_context}
  end

  def estimate_tokens(_conversation, _prompt, _fixed_input_tokens),
    do: {:error, :invalid_dynamic_context}

  defp conversation_input(%{"role" => "user", "content" => content}),
    do: user_input(content)

  defp conversation_input(%{"role" => "assistant", "content" => content}) do
    %{
      "type" => "message",
      "role" => "assistant",
      "content" => [%{"type" => "output_text", "text" => content}]
    }
  end

  defp conversation_input(_message), do: raise(ArgumentError, "invalid conversation message")

  defp user_input(content) do
    %{
      "type" => "message",
      "role" => "user",
      "content" => [%{"type" => "input_text", "text" => content}]
    }
  end

  defp tokens_for_bytes(bytes), do: div(bytes + 2, 3)
end
