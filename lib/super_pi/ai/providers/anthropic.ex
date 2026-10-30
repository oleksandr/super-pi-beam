defmodule SuperPi.AI.Providers.Anthropic do
  @moduledoc """
  Anthropic Messages API (`claude-*`).

  Configure with `ANTHROPIC_API_KEY` or `config :super_pi, anthropic_api_key: "..."`.
  Other settings (all optional):

  | Config key | Default |
  |---|---|
  | `:anthropic_base_url` | `https://api.anthropic.com` |
  | `:anthropic_models` | the models listed in `/v1/models` and the CLI |
  | `:anthropic_max_tokens` | `8192` (the API requires a limit) |
  | `:anthropic_version` | `2023-06-01` |

  What is not done:

  - **Extended thinking is not enabled.** A thinking block in the history (for example from an
    earlier turn on another provider) is dropped, because Anthropic needs the signed block back
    unchanged and thinking is off. Turning thinking on needs the signatures to round-trip, which
    has not been verified against the live API.
  - `--json-schema` structured output is ignored.
  - Prompt caching markers are not sent.

  The request and the stream parsing are tested against a local server that replays the documented
  event format. They have not run against the live API (no key was available); see
  `test/super_pi/ai/live_provider_test.exs` for the opt-in live test.
  """

  @behaviour SuperPi.AI.Provider

  alias SuperPi.AI.Providers.HTTP

  @default_models [
    {"claude-fable-5-1", "Claude Fable 5.1"},
    {"claude-opus-5-5", "Claude Opus 5.5"},
    {"claude-sonnet-5-5", "Claude Sonnet 5.5"},
    {"claude-haiku-5-5", "Claude Haiku 5.5"}
  ]

  @impl true
  def id, do: "anthropic"

  @impl true
  def handles?(model), do: String.starts_with?(model, "claude-") or String.starts_with?(model, "anthropic/")

  @impl true
  def configured?, do: is_binary(api_key()) and api_key() != ""

  @impl true
  def models do
    configured = Application.get_env(:super_pi, :anthropic_models)

    case configured do
      list when is_list(list) -> Enum.map(list, &%{"id" => &1, "label" => &1})
      _ -> Enum.map(@default_models, fn {id, label} -> %{"id" => id, "label" => label} end)
    end
  end

  @impl true
  def normalize_model("anthropic/" <> rest), do: rest
  def normalize_model(model), do: model

  @impl true
  def generate(payload, opts) do
    case api_key() do
      key when is_binary(key) and key != "" ->
        model = normalize_model(to_string(Map.get(payload, :model)))
        url = String.trim_trailing(base_url(), "/") <> "/v1/messages"

        headers = [
          {"x-api-key", key},
          {"anthropic-version", Application.get_env(:super_pi, :anthropic_version, "2023-06-01")}
        ]

        HTTP.stream(:anthropic, model, url, headers, build_body(payload, model), opts)

      _ ->
        {:error, :missing_anthropic_api_key}
    end
  end

  @doc "The request body for a provider payload."
  def build_body(payload, model \\ nil) do
    system = payload |> Map.get(:system_sections, []) |> system_text()

    %{
      "model" => model || normalize_model(to_string(Map.get(payload, :model))),
      "max_tokens" => Application.get_env(:super_pi, :anthropic_max_tokens, 8192),
      "stream" => true,
      "messages" => payload |> Map.get(:messages, []) |> to_messages()
    }
    |> put_unless_empty("system", system)
    |> put_unless_empty("tools", payload |> Map.get(:tools, []) |> Enum.map(&to_tool/1))
  end

  defp system_text(sections) do
    sections |> Enum.map(&(Map.get(&1, "content") || Map.get(&1, :content) || "")) |> Enum.reject(&(&1 == "")) |> Enum.join("\n\n")
  end

  defp put_unless_empty(map, _key, value) when value in ["", []], do: map
  defp put_unless_empty(map, key, value), do: Map.put(map, key, value)

  defp to_tool(%{"name" => name} = tool) do
    %{
      "name" => name,
      "description" => Map.get(tool, "description") || "Execute #{name}",
      "input_schema" => SuperPi.AI.ToolSchemas.parameters(tool, name)
    }
  end

  # --- Messages ---
  #
  # Anthropic wants the results of one assistant turn's tool calls together, in the single user message
  # that follows it, and no empty messages. So tool results are merged into the previous user message,
  # and consecutive user messages are merged.

  defp to_messages(messages) do
    messages
    |> Enum.flat_map(&convert/1)
    |> Enum.reduce([], &merge/2)
    |> Enum.reverse()
  end

  defp convert(%{"role" => "tool"} = m) do
    block = %{
      "type" => "tool_result",
      "tool_use_id" => m["tool_call_id"],
      "content" => tool_output(m["content"])
    }

    [%{"role" => "user", "content" => [if(m["is_error"] == true, do: Map.put(block, "is_error", true), else: block)]}]
  end

  defp convert(%{"role" => "user", "content" => content}) do
    case user_blocks(content) do
      [] -> []
      blocks -> [%{"role" => "user", "content" => blocks}]
    end
  end

  defp convert(%{"role" => "assistant", "content" => content}) when is_list(content) do
    blocks =
      Enum.flat_map(content, fn
        %{"type" => "text", "text" => t} when is_binary(t) and t != "" -> [%{"type" => "text", "text" => t}]
        %{"type" => "tool_call", "id" => id, "name" => name} = b -> [%{"type" => "tool_use", "id" => id, "name" => name, "input" => b["arguments"] || %{}}]
        # Thinking blocks are dropped (see the moduledoc).
        _ -> []
      end)

    if blocks == [], do: [], else: [%{"role" => "assistant", "content" => blocks}]
  end

  defp convert(%{"role" => "assistant", "content" => text}) when is_binary(text) and text != "" do
    [%{"role" => "assistant", "content" => [%{"type" => "text", "text" => text}]}]
  end

  defp convert(_other), do: []

  defp user_blocks(text) when is_binary(text), do: if(String.trim(text) == "", do: [], else: [%{"type" => "text", "text" => text}])

  defp user_blocks(blocks) when is_list(blocks) do
    Enum.flat_map(blocks, fn
      %{"type" => "text", "text" => t} when is_binary(t) and t != "" ->
        [%{"type" => "text", "text" => t}]

      %{"type" => "image", "source" => src} ->
        [%{"type" => "image", "source" => %{"type" => "base64", "media_type" => src["media_type"] || "image/png", "data" => src["data"] || ""}}]

      _ ->
        []
    end)
  end

  defp user_blocks(_), do: []

  defp merge(%{"role" => "user", "content" => new}, [%{"role" => "user", "content" => prev} = last | rest]) do
    # Tool results first: the API requires them at the start of the message that answers tool_use.
    {results, others} = Enum.split_with(prev ++ new, &(&1["type"] == "tool_result"))
    [%{last | "content" => results ++ others} | rest]
  end

  defp merge(message, acc), do: [message | acc]

  defp tool_output(output) when is_binary(output), do: output
  defp tool_output(output), do: Jason.encode!(output)

  defp api_key, do: Application.get_env(:super_pi, :anthropic_api_key) || System.get_env("ANTHROPIC_API_KEY")
  defp base_url, do: Application.get_env(:super_pi, :anthropic_base_url, "https://api.anthropic.com")
end
