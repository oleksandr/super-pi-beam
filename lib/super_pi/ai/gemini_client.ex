defmodule SuperPi.AI.GeminiClient do
  @moduledoc """
  Direct Google Generative AI (Gemini) client with SSE streaming, tool-calling schemas,
  and cross-provider model normalization (`spec.md` §3).

  Communicates via `Req` using Gemini's official `streamGenerateContent?alt=sse` endpoint:
  - Model defaults to `gemini-3-flash-preview` or `gemini-2.5-flash`.
  - Normalizes tool declarations from OpenAI/JSON-schema into Gemini function declaration specs.
  - Automatically translates tool calls and results between SuperPi standard messages and Gemini `parts`.
  """

  alias SuperPi.AI.StreamNormalizer

  @default_gemini_model "gemini-3-flash-preview"
  @api_base "https://generativelanguage.googleapis.com/v1beta/models"

  @doc """
  Returns the active Google Gemini API key from system environment or config.
  """
  def api_key do
    case System.get_env("GEMINI_API_KEY") do
      key when is_binary(key) and key != "" ->
        key

      _ ->
        case Application.get_env(:super_pi, :gemini_api_key) do
          key when is_binary(key) and key != "" -> key
          _ -> nil
        end
    end
  end

  @doc """
  Returns true if a valid Gemini API key is configured and not running under mock LLM mode.
  """
  def configured? do
    if Application.get_env(:super_pi, :mock_llm, false) do
      false
    else
      case api_key() do
        k when is_binary(k) and byte_size(k) > 0 -> true
        _ -> false
      end
    end
  end

  @doc """
  Streams a generation request to the live Gemini API (`streamGenerateContent?alt=sse`),
  normalizing SSE chunks through `SuperPi.AI.StreamNormalizer`, and optionally invokes
  `on_delta.(event)` as tokens stream in.
  """
  def generate(payload, opts \\ []) when is_map(payload) do
    case api_key() do
      nil ->
        {:error, :missing_gemini_api_key}

      key ->
        model = normalize_gemini_model(Map.get(payload, :model, @default_gemini_model))
        on_delta = Keyword.get(opts, :on_delta, fn _ev -> :ok end)
        url = "#{@api_base}/#{model}:streamGenerateContent?alt=sse"
        headers = [{"x-goog-api-key", key}]
        body = build_gemini_body(payload)

        normalizer_init = StreamNormalizer.new(:google, model)

        # Use Req with finch/into callback to process SSE chunks live
        res =
          Req.post(url,
            headers: headers,
            json: body,
            receive_timeout: 60_000,
            into: fn {:data, chunk}, {req, resp} ->
              st = Req.Response.get_private(resp, :normalizer, normalizer_init)
              {events, next_st} = StreamNormalizer.feed_chunk(st, chunk)

              Enum.each(events, fn ev ->
                on_delta.(ev)
              end)

              # Newest first; reversed once when the stream ends.
              events_rev = Enum.reverse(events, Req.Response.get_private(resp, :events_rev, []))

              resp =
                resp
                |> Req.Response.put_private(:normalizer, next_st)
                |> Req.Response.put_private(:events_rev, events_rev)
                |> Req.Response.put_private(
                  :raw_chunks,
                  Req.Response.get_private(resp, :raw_chunks, "") <> chunk
                )

              {:cont, {req, resp}}
            end
          )

        case res do
          {:ok, %Req.Response{status: 200} = resp} ->
            st = Req.Response.get_private(resp, :normalizer, normalizer_init)
            {flush_evs, final_st} = StreamNormalizer.flush(st)
            Enum.each(flush_evs, on_delta)
            events = Enum.reverse(Req.Response.get_private(resp, :events_rev, []), flush_evs)

            error =
              Enum.find_value(events, fn
                {:error, err} -> err
                _ -> nil
              end)

            done =
              Enum.find_value(Enum.reverse(events), fn
                {:done, d} -> d
                _ -> nil
              end)

            case {error, done} do
              {%{retryable: true}, _} ->
                {:retry_after, 2_000}

              # The stream ended before a `finishReason`: the answer may be cut, so retry it.
              {nil, nil} ->
                {:retry_after, 2_000}

              {nil, done_payload} ->
                {:ok,
                 %{
                   "role" => "assistant",
                   "provider" => "google",
                   "model" => model,
                   "content" => done_payload.content,
                   "usage" => final_st.usage
                 }}

              {err, _} ->
                {:error, err}
            end

          {:ok, %Req.Response{status: 429}} ->
            {:retry_after, 2_000}

          {:ok, %Req.Response{status: status, body: err_body} = resp} ->
            raw = Req.Response.get_private(resp, :raw_chunks, "")
            {:error, {:gemini_http_error, status, err_body, raw}}

          {:error, exception} ->
            {:error, exception}
        end
    end
  end

  @doc """
  Translates a `SuperPi` provider payload (`messages`, `system_sections`, `tools`) into the
  Google Gemini `generateContent` JSON structure.
  """
  def build_gemini_body(payload) do
    system_text =
      payload
      |> Map.get(:system_sections, [])
      |> Enum.map(fn s -> Map.get(s, "content") || Map.get(s, :content, "") end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    contents = build_gemini_contents(Map.get(payload, :messages, []))

    tools = Map.get(payload, :tools, [])

    base = %{
      "contents" => contents
    }

    base =
      if system_text != "" do
        Map.put(base, "systemInstruction", %{"parts" => [%{"text" => system_text}]})
      else
        base
      end

    base =
      if tools != [] do
        decls = Enum.map(tools, &to_gemini_function_declaration/1)
        Map.put(base, "tools", [%{"functionDeclarations" => decls}])
      else
        base
      end

    case Map.get(payload, :json_schema) || Map.get(payload, "json_schema") do
      schema when is_map(schema) and map_size(schema) > 0 ->
        Map.put(base, "generationConfig", %{
          "responseMimeType" => "application/json",
          "responseSchema" => to_gemini_schema(schema)
        })

      _ ->
        base
    end
  end

  defp build_gemini_contents(messages) when is_list(messages) do
    tool_name_map = build_tool_name_map(messages)

    messages
    |> Enum.reduce([], fn msg, acc ->
      role = Map.get(msg, "role") || Map.get(msg, :role)

      case to_string(role) do
        "tool" ->
          call_id = Map.get(msg, "tool_call_id") || Map.get(msg, :tool_call_id)

          name =
            Map.get(msg, "name") || Map.get(msg, :name) || Map.get(tool_name_map, call_id, "tool")

          output = Map.get(msg, "content") || Map.get(msg, :content, "")
          formatted = format_tool_result(output)
          resp_body = if is_map(output), do: output, else: %{"result" => formatted}
          part = %{"functionResponse" => %{"name" => name, "response" => resp_body}}

          case acc do
            [%{"role" => "user", "parts" => existing_parts} = last | rest] ->
              if Enum.any?(existing_parts, &Map.has_key?(&1, "functionResponse")) do
                [%{last | "parts" => existing_parts ++ [part]} | rest]
              else
                [%{"role" => "user", "parts" => [part]} | acc]
              end

            _ ->
              [%{"role" => "user", "parts" => [part]} | acc]
          end

        _ ->
          case to_gemini_content(msg) do
            nil -> acc
            content -> [content | acc]
          end
      end
    end)
    |> Enum.reverse()
  end

  defp build_tool_name_map(messages) do
    Enum.reduce(messages, %{}, fn msg, acc ->
      case Map.get(msg, "content") || Map.get(msg, :content) do
        blocks when is_list(blocks) ->
          Enum.reduce(blocks, acc, fn
            %{"type" => "tool_call", "id" => id, "name" => name}, m_acc when is_binary(id) ->
              Map.put(m_acc, id, name)

            %{type: "tool_call", id: id, name: name}, m_acc when is_binary(id) ->
              Map.put(m_acc, id, name)

            _, m_acc ->
              m_acc
          end)

        _ ->
          acc
      end
    end)
  end

  defp format_tool_result(output) when is_binary(output), do: output

  defp format_tool_result(output) when is_map(output) or is_list(output) do
    case Jason.encode(output) do
      {:ok, json} -> json
      _ -> inspect(output)
    end
  end

  defp format_tool_result(output), do: to_string(output)

  defp to_gemini_content(%{"role" => "user", "content" => blocks}) when is_list(blocks) do
    parts =
      blocks
      |> Enum.map(fn
        %{"type" => "text", "text" => t} ->
          %{"text" => t}

        %{type: "text", text: t} ->
          %{"text" => t}

        %{"type" => "image", "source" => src} ->
          media_type = Map.get(src, "media_type") || Map.get(src, :media_type, "image/png")
          data = Map.get(src, "data") || Map.get(src, :data, "")
          %{"inlineData" => %{"mimeType" => media_type, "data" => data}}

        %{type: "image", source: src} ->
          media_type = Map.get(src, "media_type") || Map.get(src, :media_type, "image/png")
          data = Map.get(src, "data") || Map.get(src, :data, "")
          %{"inlineData" => %{"mimeType" => media_type, "data" => data}}

        other ->
          %{"text" => inspect(other)}
      end)

    %{"role" => "user", "parts" => parts}
  end

  defp to_gemini_content(%{"role" => "user", "content" => text}) when is_binary(text) do
    %{"role" => "user", "parts" => [%{"text" => text}]}
  end

  defp to_gemini_content(%{"role" => "assistant", "content" => blocks}) when is_list(blocks) do
    parts =
      blocks
      |> Enum.map(fn
        %{"type" => "thinking", "thinking" => t, "signature" => sig} ->
          base = %{"thought" => true, "text" => t}
          if sig, do: Map.put(base, "thoughtSignature", sig), else: base

        %{"type" => "text", "text" => t} = b ->
          base = %{"text" => t}

          if b["thoughtSignature"],
            do: Map.put(base, "thoughtSignature", b["thoughtSignature"]),
            else: base

        %{"type" => "tool_call", "name" => name, "arguments" => args} = b ->
          base = %{"functionCall" => %{"name" => name, "args" => args || %{}}}

          if b["thoughtSignature"],
            do: Map.put(base, "thoughtSignature", b["thoughtSignature"]),
            else: base

        _ ->
          nil
      end)
      |> Enum.reject(&is_nil/1)

    if parts == [], do: nil, else: %{"role" => "model", "parts" => parts}
  end

  defp to_gemini_content(_), do: nil

  defp to_gemini_function_declaration(%{"name" => name} = tool) do
    %{
      "name" => name,
      "description" => Map.get(tool, "description", "Execute #{name}"),
      "parameters" => tool |> SuperPi.AI.ToolSchemas.parameters(name) |> to_gemini_schema()
    }
  end

  # Gemini takes an OpenAPI subset of JSON Schema: upper-case type names, one type per schema,
  # and no keys outside that subset (`additionalProperties`, `$schema` and the like are refused).
  @gemini_schema_keys ~w(type format title description nullable enum minItems maxItems minProperties
                         maxProperties minLength maxLength pattern minimum maximum default example
                         propertyOrdering required)

  @doc false
  def to_gemini_schema(%{} = schema) do
    {type, nullable?} = gemini_type(Map.get(schema, "type"))

    schema
    |> Map.take(@gemini_schema_keys)
    |> put_present("type", type)
    |> then(&if(nullable?, do: Map.put(&1, "nullable", true), else: &1))
    |> put_present("properties", map_values(Map.get(schema, "properties"), &to_gemini_schema/1))
    |> put_present("items", if(is_map(schema["items"]), do: to_gemini_schema(schema["items"])))
    |> put_present(
      "anyOf",
      if(is_list(schema["anyOf"]), do: Enum.map(schema["anyOf"], &to_gemini_schema/1))
    )
  end

  def to_gemini_schema(_other), do: %{"type" => "OBJECT", "properties" => %{}}

  defp gemini_type(type) when is_binary(type), do: {String.upcase(type), false}

  defp gemini_type(types) when is_list(types) do
    case Enum.reject(types, &(&1 == "null")) do
      [type | _] -> {String.upcase(type), "null" in types}
      [] -> {nil, true}
    end
  end

  defp gemini_type(_), do: {nil, false}

  defp map_values(%{} = map, fun), do: Map.new(map, fn {k, v} -> {k, fun.(v)} end)
  defp map_values(_, _fun), do: nil

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp normalize_gemini_model(model) when is_binary(model) do
    cleaned =
      model
      |> String.replace_prefix("models/", "")
      |> String.replace_prefix("google/", "")

    valid_model =
      if String.starts_with?(cleaned, "gemini-") do
        cleaned
      else
        @default_gemini_model
      end

    URI.encode(valid_model, fn ch ->
      ch in ?a..?z or ch in ?A..?Z or ch in ?0..?9 or ch in [?-, ?_]
    end)
  end

  defp normalize_gemini_model(_), do: @default_gemini_model
end
