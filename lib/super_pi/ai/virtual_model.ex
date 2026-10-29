defmodule SuperPi.AI.VirtualModel do
  @moduledoc """
  Virtual Model Router and Prompt-Cache Session Affinity Manager (`spec.md` §4, Step 5).

  Provides:
  - Virtual model aliases (`"fast"`, `"balanced"`, `"deep"`, `"coding"`) that dynamically resolve
    to concrete `{provider, model_id, thinking_budget}` tuples based on task phase, complexity, or
    fallback health.
  - Prompt-cache session affinity via `pi.provider` (`UUIDv7`): preserves the same `sessionId`
    across linear turns and allocates a fresh `UUIDv7` when a conversation forks.
  """

  alias SuperPi.Durable.Doc
  alias SuperPi.Durable.Storage

  @virtual_models %{
    "fast" => %{
      provider: :anthropic,
      model: "claude-haiku-4-5",
      thinking_budget: 0,
      fallback: {:google, "gemini-3-flash-preview"}
    },
    "balanced" => %{
      provider: :anthropic,
      model: "claude-sonnet-4-5",
      thinking_budget: 4_096,
      fallback: {:openai, "gpt-5"}
    },
    "deep" => %{
      provider: :anthropic,
      model: "claude-opus-4-5",
      thinking_budget: 16_384,
      fallback: {:google, "gemini-3.1-pro-preview"}
    },
    "coding" => %{
      provider: :anthropic,
      model: "claude-sonnet-4-5",
      thinking_budget: 8_192,
      fallback: {:openai, "gpt-5"}
    }
  }

  @doc """
  Resolves a virtual model name (or explicit `"provider/model"` string) into a normalized
  routing descriptor `%{provider: atom(), model: String.t(), thinking_budget: non_neg_integer()}`.
  """
  def resolve(model_spec, opts \\ [])

  def resolve("", _opts), do: raise(ArgumentError, "model_spec cannot be empty")

  def resolve(model_spec, opts) when is_binary(model_spec) do
    use_fallback? = Keyword.get(opts, :fallback, false)

    case Map.get(@virtual_models, model_spec) do
      %{provider: p, model: m, thinking_budget: tb, fallback: {fp, fm}} ->
        if use_fallback? do
          %{provider: fp, model: fm, thinking_budget: tb, virtual_name: model_spec}
        else
          %{provider: p, model: m, thinking_budget: tb, virtual_name: model_spec}
        end

      nil ->
        case String.split(model_spec, "/", parts: 2) do
          [prov_str, mod_id] ->
            if mod_id == "" do
              raise ArgumentError, "model id cannot be empty in #{inspect(model_spec)}"
            end

            %{
              provider: parse_provider(prov_str),
              model: mod_id,
              thinking_budget: Keyword.get(opts, :thinking_budget, 0),
              virtual_name: nil
            }

          [mod_id] ->
            if mod_id == "" do
              raise ArgumentError, "model id cannot be empty"
            end

            provider =
              cond do
                Keyword.has_key?(opts, :provider) ->
                  Keyword.get(opts, :provider)

                String.starts_with?(mod_id, ["claude-", "anthropic"]) ->
                  :anthropic

                String.starts_with?(mod_id, ["gpt-", "o1", "o3", "o4", "chatgpt"]) ->
                  :openai

                String.starts_with?(mod_id, ["gemini-", "google"]) ->
                  :google

                true ->
                  raise ArgumentError, "cannot infer provider for model #{inspect(mod_id)}"
              end

            %{
              provider: provider,
              model: mod_id,
              thinking_budget: Keyword.get(opts, :thinking_budget, 0),
              virtual_name: nil
            }
        end
    end
  end

  @doc """
  Ensures the conversation has a `pi.provider` document with a stable `sessionId` (`UUIDv7`)
  for LLM prompt-cache affinity (`spec.md` §4.3).
  """
  def ensure_provider_session!(conversation_id, provider, model) do
    current = Doc.snapshot("conversation", conversation_id, "pi.provider") || %{}

    existing_session_id = Map.get(current, "sessionId")
    existing_provider = Map.get(current, "provider")
    existing_model = Map.get(current, "model")

    if is_binary(existing_session_id) and byte_size(existing_session_id) > 0 and
         existing_provider == to_string(provider) and existing_model == model do
      current
    else
      Storage.commit(fn seq ->
        curr = Doc.snapshot("conversation", conversation_id, "pi.provider") || %{}
        sess_id = Map.get(curr, "sessionId")

        session_id =
          if is_binary(sess_id) and byte_size(sess_id) > 0 do
            sess_id
          else
            Uniq.UUID.uuid7()
          end

        last_warmed = Map.get(curr, "lastWarmedAt") || System.system_time(:millisecond)

        updated = %{
          "sessionId" => session_id,
          "provider" => to_string(provider),
          "model" => model,
          "lastWarmedAt" => last_warmed
        }

        Doc.put_doc("conversation", conversation_id, "pi.provider", updated, seq)
        updated
      end)
    end
  end

  defp parse_provider("anthropic"), do: :anthropic
  defp parse_provider("openai"), do: :openai
  defp parse_provider("google"), do: :google

  defp parse_provider(other) do
    raise ArgumentError, "unknown provider: #{inspect(other)}"
  end
end
