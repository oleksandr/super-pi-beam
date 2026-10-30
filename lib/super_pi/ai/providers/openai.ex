defmodule SuperPi.AI.Providers.OpenAI do
  @moduledoc """
  OpenAI Chat Completions API (`gpt-*`, `o1*`, `o3*`, `o4*`), and any server that speaks it.

  Configure with `OPENAI_API_KEY` or `config :super_pi, openai_api_key: "..."`. Other settings:

  | Config key | Default |
  |---|---|
  | `:openai_base_url` | `https://api.openai.com/v1` |
  | `:openai_models` | the models listed in `/v1/models` and the CLI |
  | `:openai_max_tokens` | unset (the API's default) |

  Point `:openai_base_url` at an OpenAI-compatible server (Azure OpenAI, vLLM, Ollama, a proxy) to use
  it. Models for such a server are listed with `:openai_models`, and a name that this module does not
  claim can be routed here by registering a provider that wraps it (see `SuperPi.AI.Provider`).

  What is not done: the Responses API (only Chat Completions is used), reasoning summaries, and
  prompt caching controls.

  The request and the stream parsing are tested against a local server that replays the documented
  event format. They have not run against the live API (no key was available); see
  `test/super_pi/ai/live_provider_test.exs` for the opt-in live test.
  """

  @behaviour SuperPi.AI.Provider

  alias SuperPi.AI.Providers.HTTP

  @default_models ["gpt-5", "gpt-5-mini"]

  @impl true
  def id, do: "openai"

  @impl true
  def handles?(model) do
    String.starts_with?(model, ["gpt-", "chatgpt-", "openai/", "o1", "o3", "o4"])
  end

  @impl true
  def configured?, do: is_binary(api_key()) and api_key() != ""

  @impl true
  def models do
    list = Application.get_env(:super_pi, :openai_models, @default_models)
    Enum.map(list, &%{"id" => &1, "label" => &1})
  end

  @impl true
  def normalize_model("openai/" <> rest), do: rest
  def normalize_model(model), do: model

  @impl true
  def generate(payload, opts) do
    case api_key() do
      key when is_binary(key) and key != "" ->
        model = normalize_model(to_string(Map.get(payload, :model)))
        url = String.trim_trailing(base_url(), "/") <> "/chat/completions"
        HTTP.stream(:openai, model, url, [{"authorization", "Bearer " <> key}], build_body(payload, model), opts)

      _ ->
        {:error, :missing_openai_api_key}
    end
  end

  @doc "The request body for a provider payload."
  def build_body(payload, model \\ nil) do
    system = payload |> Map.get(:system_sections, []) |> Enum.map(&(Map.get(&1, "content") || "")) |> Enum.reject(&(&1 == "")) |> Enum.join("\n\n")
    messages = payload |> Map.get(:messages, []) |> Enum.flat_map(&convert/1)
    messages = if system == "", do: messages, else: [%{"role" => "system", "content" => system} | messages]

    %{
      "model" => model || normalize_model(to_string(Map.get(payload, :model))),
      "stream" => true,
      # Without this the API sends no token counts in a stream.
      "stream_options" => %{"include_usage" => true},
      "messages" => messages
    }
    |> put_tools(Map.get(payload, :tools, []))
    |> put_max_tokens()
    |> put_response_format(Map.get(payload, :json_schema))
  end

  defp put_tools(body, []), do: body

  defp put_tools(body, tools) do
    Map.put(body, "tools", Enum.map(tools, &to_tool/1))
  end

  defp to_tool(%{"name" => name} = tool) do
    %{
      "type" => "function",
      "function" => %{
        "name" => name,
        "description" => Map.get(tool, "description") || "Execute #{name}",
        "parameters" => SuperPi.AI.ToolSchemas.parameters(tool, name)
      }
    }
  end

  defp put_max_tokens(body) do
    case Application.get_env(:super_pi, :openai_max_tokens) do
      n when is_integer(n) and n > 0 -> Map.put(body, "max_completion_tokens", n)
      _ -> body
    end
  end

  defp put_response_format(body, schema) when is_map(schema) do
    Map.put(body, "response_format", %{"type" => "json_schema", "json_schema" => %{"name" => "response", "schema" => schema}})
  end

  defp put_response_format(body, _), do: body

  defp convert(%{"role" => "tool"} = m) do
    [%{"role" => "tool", "tool_call_id" => m["tool_call_id"], "content" => tool_output(m["content"])}]
  end

  defp convert(%{"role" => "user", "content" => content}) do
    case user_content(content) do
      nil -> []
      value -> [%{"role" => "user", "content" => value}]
    end
  end

  defp convert(%{"role" => "assistant", "content" => content}) when is_list(content) do
    text = content |> Enum.flat_map(fn %{"type" => "text", "text" => t} when is_binary(t) -> [t]; _ -> [] end) |> Enum.join("")

    calls =
      for %{"type" => "tool_call", "id" => id, "name" => name} = b <- content do
        %{"id" => id, "type" => "function", "function" => %{"name" => name, "arguments" => Jason.encode!(b["arguments"] || %{})}}
      end

    cond do
      calls != [] -> [%{"role" => "assistant", "content" => if(text == "", do: nil, else: text), "tool_calls" => calls}]
      text != "" -> [%{"role" => "assistant", "content" => text}]
      true -> []
    end
  end

  defp convert(%{"role" => "assistant", "content" => text}) when is_binary(text) and text != "", do: [%{"role" => "assistant", "content" => text}]
  defp convert(_other), do: []

  defp user_content(text) when is_binary(text), do: if(String.trim(text) == "", do: nil, else: text)

  defp user_content(blocks) when is_list(blocks) do
    parts =
      Enum.flat_map(blocks, fn
        %{"type" => "text", "text" => t} when is_binary(t) and t != "" ->
          [%{"type" => "text", "text" => t}]

        %{"type" => "image", "source" => src} ->
          [%{"type" => "image_url", "image_url" => %{"url" => "data:#{src["media_type"] || "image/png"};base64,#{src["data"] || ""}"}}]

        _ ->
          []
      end)

    case parts do
      [] -> nil
      [%{"type" => "text", "text" => t}] -> t
      many -> many
    end
  end

  defp user_content(_), do: nil

  defp tool_output(output) when is_binary(output), do: output
  defp tool_output(output), do: Jason.encode!(output)

  defp api_key, do: Application.get_env(:super_pi, :openai_api_key) || System.get_env("OPENAI_API_KEY")
  defp base_url, do: Application.get_env(:super_pi, :openai_base_url, "https://api.openai.com/v1")
end
