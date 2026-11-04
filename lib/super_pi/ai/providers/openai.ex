defmodule SuperPi.AI.Providers.OpenAI do
  @moduledoc """
  OpenAI Chat Completions and Responses APIs (`gpt-*`, `o1*`, `o3*`, `o4*`).

  Configure with `OPENAI_API_KEY` or `config :super_pi, openai_api_key: "..."`. Other settings:

  | Config key | Default |
  |---|---|
  | `:openai_base_url` | `https://api.openai.com/v1` |
  | `:openai_models` | the models listed in `/v1/models` and the CLI |
  | `:openai_max_tokens` | unset (the API's default) |
  | `:openai_auth_command` | unset; an executable that prints a short-lived bearer token to stdout |
  | `:openai_auth_timeout_ms` | `10000` |
  | `:openai_auth_cache_ttl_ms` | `60000`; JWT expiry can shorten this, `0` disables caching |
  | `:openai_responses_models` | `["gpt-6-astra"]` |
  | `:openai_reasoning_effort` | `%{"gpt-6-sol" => "none"}`; a map from model name to effort |

  Point `:openai_base_url` at an OpenAI-compatible server (Azure OpenAI, vLLM, Ollama, a proxy) to use
  it. Models for such a server are listed with `:openai_models`; configured model names are also
  recognized by this provider, including gateway aliases.

  GPT-6 Astra uses the Responses API because its Chat Completions endpoint does not support
  function calls at the reasoning efforts the model accepts. Configure additional Responses models
  with `:openai_responses_models` and model effort with `:openai_reasoning_effort`.
  Reasoning summaries and prompt caching controls are not implemented.

  The request and the stream parsing are tested against a local server that replays the documented
  event format. See `test/super_pi/ai/live_provider_test.exs` for the opt-in live test.
  """

  @behaviour SuperPi.AI.Provider

  alias SuperPi.AI.Providers.HTTP
  alias SuperPi.AI.Providers.OpenAI.Auth

  @default_models ["gpt-5", "gpt-5-mini"]
  @default_responses_models ["gpt-6-astra"]
  @default_reasoning_effort %{"gpt-6-sol" => "none"}

  @impl true
  def id, do: "openai"

  @impl true
  def handles?(model) do
    String.starts_with?(model, ["gpt-", "chatgpt-", "openai/", "o1", "o3", "o4"]) or
      normalize_model(model) in Application.get_env(:super_pi, :openai_models, @default_models)
  end

  @impl true
  def configured? do
    key = static_api_key()
    command = auth_command()

    (is_binary(key) and key != "") or
      (is_binary(command) and System.find_executable(command) != nil)
  end

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
      {:ok, key} ->
        model = normalize_model(to_string(Map.get(payload, :model)))

        {path, body} =
          if model in Application.get_env(
               :super_pi,
               :openai_responses_models,
               @default_responses_models
             ) do
            {"/responses", build_responses_body(payload, model)}
          else
            {"/chat/completions", build_body(payload, model)}
          end

        url = String.trim_trailing(base_url(), "/") <> path

        HTTP.stream(
          :openai,
          model,
          url,
          [{"authorization", "Bearer " <> key}],
          body,
          opts
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "The request body for a provider payload."
  def build_body(payload, model \\ nil) do
    system = system_prompt(payload)

    messages = payload |> Map.get(:messages, []) |> Enum.flat_map(&convert/1)

    messages =
      if system == "", do: messages, else: [%{"role" => "system", "content" => system} | messages]

    %{
      "model" => model || normalize_model(to_string(Map.get(payload, :model))),
      "stream" => true,
      # Without this the API sends no token counts in a stream.
      "stream_options" => %{"include_usage" => true},
      "messages" => messages
    }
    |> put_tools(Map.get(payload, :tools, []))
    |> put_max_tokens("max_completion_tokens")
    |> put_response_format(Map.get(payload, :json_schema))
    |> put_reasoning_effort(model || Map.get(payload, :model), :chat)
  end

  defp put_reasoning_effort(body, model, api) do
    efforts = Application.get_env(:super_pi, :openai_reasoning_effort, @default_reasoning_effort)

    case Map.get(efforts, normalize_model(model)) do
      nil -> body
      effort when api == :chat -> Map.put(body, "reasoning_effort", effort)
      effort -> Map.put(body, "reasoning", %{"effort" => effort})
    end
  end

  @doc "The Responses API body used for GPT-6 Astra."
  def build_responses_body(payload, model \\ nil) do
    body = %{
      "model" => model || normalize_model(to_string(Map.get(payload, :model))),
      "stream" => true,
      "input" => payload |> Map.get(:messages, []) |> Enum.flat_map(&convert_response/1)
    }

    body
    |> maybe_put_instructions(system_prompt(payload))
    |> put_responses_tools(Map.get(payload, :tools, []))
    |> put_max_tokens("max_output_tokens")
    |> put_responses_format(Map.get(payload, :json_schema))
    |> put_reasoning_effort(model || Map.get(payload, :model), :responses)
  end

  defp system_prompt(payload) do
    payload
    |> Map.get(:system_sections, [])
    |> Enum.map(&(Map.get(&1, "content") || ""))
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp maybe_put_instructions(body, ""), do: body
  defp maybe_put_instructions(body, system), do: Map.put(body, "instructions", system)

  defp put_responses_tools(body, []), do: body

  defp put_responses_tools(body, tools) do
    Map.put(body, "tools", Enum.map(tools, &to_response_tool/1))
  end

  defp to_response_tool(%{"name" => name} = tool) do
    tool_definition(tool, name)
    |> Map.merge(%{"type" => "function", "strict" => false})
  end

  defp put_responses_format(body, schema) when is_map(schema) do
    Map.put(body, "text", %{
      "format" => %{"type" => "json_schema", "name" => "response", "schema" => schema}
    })
  end

  defp put_responses_format(body, _), do: body

  defp convert_response(%{"role" => "tool"} = message) do
    [
      %{
        "type" => "function_call_output",
        "call_id" => message["tool_call_id"],
        "output" => tool_output(message["content"])
      }
    ]
  end

  defp convert_response(%{"role" => "user", "content" => content}) do
    case responses_user_content(content) do
      nil -> []
      value -> [%{"role" => "user", "content" => value}]
    end
  end

  defp convert_response(%{"role" => "assistant", "content" => content})
       when is_list(content) do
    {text, tool_calls} = assistant_parts(content)

    calls =
      for {id, name, arguments} <- tool_calls do
        %{
          "type" => "function_call",
          "call_id" => id,
          "name" => name,
          "arguments" => arguments
        }
      end

    if(text == "", do: [], else: [%{"role" => "assistant", "content" => text}]) ++ calls
  end

  defp convert_response(%{"role" => "assistant", "content" => text})
       when is_binary(text) and text != "",
       do: [%{"role" => "assistant", "content" => text}]

  defp convert_response(_), do: []

  defp responses_user_content(text) when is_binary(text),
    do: if(String.trim(text) == "", do: nil, else: text)

  defp responses_user_content(blocks) when is_list(blocks) do
    parts =
      Enum.map(user_parts(blocks), fn
        {:text, text} -> %{"type" => "input_text", "text" => text}
        {:image, url} -> %{"type" => "input_image", "image_url" => url}
      end)

    if parts == [], do: nil, else: parts
  end

  defp responses_user_content(_), do: nil

  defp put_tools(body, []), do: body

  defp put_tools(body, tools) do
    Map.put(body, "tools", Enum.map(tools, &to_tool/1))
  end

  defp to_tool(%{"name" => name} = tool) do
    %{
      "type" => "function",
      "function" => tool_definition(tool, name)
    }
  end

  defp tool_definition(tool, name) do
    %{
      "name" => name,
      "description" => Map.get(tool, "description") || "Execute #{name}",
      "parameters" => SuperPi.AI.ToolSchemas.parameters(tool, name)
    }
  end

  defp put_max_tokens(body, field) do
    case Application.get_env(:super_pi, :openai_max_tokens) do
      n when is_integer(n) and n > 0 -> Map.put(body, field, n)
      _ -> body
    end
  end

  defp put_response_format(body, schema) when is_map(schema) do
    Map.put(body, "response_format", %{
      "type" => "json_schema",
      "json_schema" => %{"name" => "response", "schema" => schema}
    })
  end

  defp put_response_format(body, _), do: body

  defp convert(%{"role" => "tool"} = m) do
    [
      %{
        "role" => "tool",
        "tool_call_id" => m["tool_call_id"],
        "content" => tool_output(m["content"])
      }
    ]
  end

  defp convert(%{"role" => "user", "content" => content}) do
    case user_content(content) do
      nil -> []
      value -> [%{"role" => "user", "content" => value}]
    end
  end

  defp convert(%{"role" => "assistant", "content" => content}) when is_list(content) do
    {text, tool_calls} = assistant_parts(content)

    calls =
      for {id, name, arguments} <- tool_calls do
        %{
          "id" => id,
          "type" => "function",
          "function" => %{"name" => name, "arguments" => arguments}
        }
      end

    cond do
      calls != [] ->
        [
          %{
            "role" => "assistant",
            "content" => if(text == "", do: nil, else: text),
            "tool_calls" => calls
          }
        ]

      text != "" ->
        [%{"role" => "assistant", "content" => text}]

      true ->
        []
    end
  end

  defp convert(%{"role" => "assistant", "content" => text}) when is_binary(text) and text != "",
    do: [%{"role" => "assistant", "content" => text}]

  defp convert(_other), do: []

  defp user_content(text) when is_binary(text),
    do: if(String.trim(text) == "", do: nil, else: text)

  defp user_content(blocks) when is_list(blocks) do
    parts =
      Enum.map(user_parts(blocks), fn
        {:text, text} -> %{"type" => "text", "text" => text}
        {:image, url} -> %{"type" => "image_url", "image_url" => %{"url" => url}}
      end)

    case parts do
      [] -> nil
      [%{"type" => "text", "text" => t}] -> t
      many -> many
    end
  end

  defp user_content(_), do: nil

  defp assistant_parts(content) do
    text =
      content
      |> Enum.flat_map(fn
        %{"type" => "text", "text" => value} when is_binary(value) -> [value]
        _ -> []
      end)
      |> Enum.join("")

    calls =
      for %{"type" => "tool_call", "id" => id, "name" => name} = block <- content,
          do: {id, name, Jason.encode!(block["arguments"] || %{})}

    {text, calls}
  end

  defp user_parts(blocks) do
    Enum.flat_map(blocks, fn
      %{"type" => "text", "text" => text} when is_binary(text) and text != "" ->
        [{:text, text}]

      %{"type" => "image", "source" => source} ->
        [{:image, "data:#{source["media_type"] || "image/png"};base64,#{source["data"] || ""}"}]

      _ ->
        []
    end)
  end

  defp tool_output(output) when is_binary(output), do: output
  defp tool_output(output), do: Jason.encode!(output)

  defp api_key do
    case static_api_key() do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> command_api_key()
    end
  end

  defp static_api_key,
    do: Application.get_env(:super_pi, :openai_api_key) || System.get_env("OPENAI_API_KEY")

  defp auth_command, do: Application.get_env(:super_pi, :openai_auth_command)

  defp command_api_key do
    case auth_command() do
      command when is_binary(command) and command != "" ->
        Auth.token(command)

      _ ->
        {:error, :missing_openai_api_key}
    end
  end

  defp base_url, do: Application.get_env(:super_pi, :openai_base_url, "https://api.openai.com/v1")
end
