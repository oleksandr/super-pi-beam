defmodule SuperPi.AI.GeminiClient do
  @moduledoc """
  Live Google Gemini (`google-generative-ai`) HTTP / SSE Provider Adapter using `Req` and
  `SuperPi.AI.StreamNormalizer`.

  Reads `GEMINI_API_KEY` (or `GOOGLE_API_KEY` / `GOOGLE_GENERATIVE_AI_API_KEY`) from the environment,
  converts `SuperPi.Durable.Context` derived messages, system sections, and tool declarations into
  the Gemini `generateContent` / `streamGenerateContent?alt=sse` schema, and returns normalized
  assistant messages (`content` blocks with `text`, `thinking`, and `tool_call` plus `usage`).
  """

  alias SuperPi.AI.StreamNormalizer

  @default_gemini_model "gemini-3-flash-preview"
  @api_base "https://generativelanguage.googleapis.com/v1beta/models"

  def api_key do
    System.get_env("GEMINI_API_KEY") ||
      System.get_env("GOOGLE_GENERATIVE_AI_API_KEY") ||
      System.get_env("GOOGLE_API_KEY")
  end

  def configured? do
    case api_key() do
      k when is_binary(k) and byte_size(k) > 0 -> true
      _ -> false
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
        url = "#{@api_base}/#{model}:streamGenerateContent?alt=sse&key=#{key}"
        body = build_gemini_body(payload)

        normalizer_init = StreamNormalizer.new(:google, model)

        # Use Req withfinch/into callback to process SSE chunks live
        res =
          Req.post(url,
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
               "usage" => done_payload.usage
             }}

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

    contents =
      payload
      |> Map.get(:messages, [])
      |> Enum.map(&to_gemini_content/1)
      |> Enum.reject(&is_nil/1)

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

    if tools != [] do
      decls = Enum.map(tools, &to_gemini_function_declaration/1)
      Map.put(base, "tools", [%{"functionDeclarations" => decls}])
    else
      base
    end
  end

  defp to_gemini_content(%{"role" => "user", "content" => blocks}) when is_list(blocks) do
    parts =
      blocks
      |> Enum.map(fn
        %{"type" => "text", "text" => t} -> %{"text" => t}
        other -> %{"text" => inspect(other)}
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

  defp to_gemini_content(%{"role" => "tool", "name" => name, "content" => output}) do
    %{
      "role" => "user",
      "parts" => [
        %{
          "functionResponse" => %{
            "name" => name,
            "response" => %{"result" => to_string(output)}
          }
        }
      ]
    }
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
        "path" => %{"type" => "STRING"},
        "old_text" => %{"type" => "STRING"},
        "new_text" => %{"type" => "STRING"}
      },
      "required" => ["path", "old_text", "new_text"]
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
    cond do
      String.starts_with?(model, "gemini-") -> model
      String.starts_with?(model, "google/") -> String.replace_prefix(model, "google/", "")
      true -> @default_gemini_model
    end
  end

  defp synthesize_done_from_state(%StreamNormalizer{} = st) do
    ordered =
      st.blocks
      |> Enum.sort_by(fn {idx, _} -> idx end)
      |> Enum.map(fn {_idx, b} -> Map.delete(b, "raw_json") end)

    %{stop_reason: st.stop_reason, content: ordered, usage: st.usage}
  end
end
