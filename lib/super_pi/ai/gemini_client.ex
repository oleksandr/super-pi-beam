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

              all_ev = Req.Response.get_private(resp, :events, []) ++ events

              resp =
                resp
                |> Req.Response.put_private(:normalizer, next_st)
                |> Req.Response.put_private(:events, all_ev)
                |> Req.Response.put_private(:raw_chunks, Req.Response.get_private(resp, :raw_chunks, "") <> chunk)

              {:cont, {req, resp}}
            end
          )

        case res do
          {:ok, %Req.Response{status: 200} = resp} ->
            st = Req.Response.get_private(resp, :normalizer, normalizer_init)
            {flush_evs, final_st} = StreamNormalizer.flush(st)
            Enum.each(flush_evs, on_delta)
            events = Req.Response.get_private(resp, :events, []) ++ flush_evs

            case Enum.find_value(events, fn {:error, err} -> err; _ -> nil end) do
              nil ->
                done_payload =
                  Enum.find_value(Enum.reverse(events), fn
                    {:done, d} -> d
                    _ -> nil
                  end) || synthesize_done_from_state(final_st)

                {:ok,
                 %{
                   "role" => "assistant",
                   "provider" => "google",
                   "model" => model,
                   "content" => done_payload.content,
                   "usage" => final_st.usage
                 }}

              err ->
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
          "responseSchema" => schema
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
          name = Map.get(msg, "name") || Map.get(msg, :name) || Map.get(tool_name_map, call_id, "tool")
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
          if b["thoughtSignature"], do: Map.put(base, "thoughtSignature", b["thoughtSignature"]), else: base

        %{"type" => "tool_call", "name" => name, "arguments" => args} = b ->
          base = %{"functionCall" => %{"name" => name, "args" => args || %{}}}
          if b["thoughtSignature"], do: Map.put(base, "thoughtSignature", b["thoughtSignature"]), else: base

        _ ->
          nil
      end)
      |> Enum.reject(&is_nil/1)

    if parts == [], do: nil, else: %{"role" => "model", "parts" => parts}
  end

  defp to_gemini_content(_), do: nil

  defp to_gemini_function_declaration(%{"name" => name} = tool) do
    desc = Map.get(tool, "description", "Execute #{name}")
    params = Map.get(tool, "parameters") || default_schema_for_builtin(name)

    %{
      "name" => name,
      "description" => desc,
      "parameters" => params
    }
  end

  defp default_schema_for_builtin("read") do
    %{
      "type" => "OBJECT",
      "properties" => %{
        "path" => %{"type" => "STRING", "description" => "File path to read"}
      },
      "required" => ["path"]
    }
  end

  defp default_schema_for_builtin("write") do
    %{
      "type" => "OBJECT",
      "properties" => %{
        "path" => %{"type" => "STRING", "description" => "File path to write"},
        "content" => %{"type" => "STRING", "description" => "Content to write"}
      },
      "required" => ["path", "content"]
    }
  end

  defp default_schema_for_builtin("edit") do
    %{
      "type" => "OBJECT",
      "properties" => %{
        "path" => %{"type" => "STRING", "description" => "File path to edit"},
        "target" => %{"type" => "STRING", "description" => "Exact snippet to replace"},
        "replacement" => %{"type" => "STRING", "description" => "New replacement text"}
      },
      "required" => ["path", "target", "replacement"]
    }
  end

  defp default_schema_for_builtin("bash") do
    %{
      "type" => "OBJECT",
      "properties" => %{
        "command" => %{"type" => "STRING", "description" => "Shell command to execute"}
      },
      "required" => ["command"]
    }
  end

  defp default_schema_for_builtin("grep") do
    %{
      "type" => "OBJECT",
      "properties" => %{
        "pattern" => %{"type" => "STRING", "description" => "Regex pattern"},
        "path" => %{"type" => "STRING", "description" => "Directory path"}
      },
      "required" => ["pattern"]
    }
  end

  defp default_schema_for_builtin("find") do
    %{
      "type" => "OBJECT",
      "properties" => %{
        "path" => %{"type" => "STRING", "description" => "Directory path"}
      }
    }
  end

  defp default_schema_for_builtin("ls") do
    %{
      "type" => "OBJECT",
      "properties" => %{
        "path" => %{"type" => "STRING", "description" => "Directory path"}
      }
    }
  end

  defp default_schema_for_builtin("tool_search") do
    %{
      "type" => "OBJECT",
      "properties" => %{
        "query" => %{"type" => "STRING", "description" => "Keyword to search deferred tools"}
      },
      "required" => ["query"]
    }
  end

  defp default_schema_for_builtin(_) do
    %{"type" => "OBJECT", "properties" => %{}}
  end

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

  defp synthesize_done_from_state(%StreamNormalizer{} = st) do
    ordered =
      st.blocks
      |> Enum.sort_by(fn {idx, _} -> idx end)
      |> Enum.map(fn {_idx, b} -> Map.delete(b, "raw_json") end)

    %{stop_reason: st.stop_reason, content: ordered, usage: st.usage}
  end
end
