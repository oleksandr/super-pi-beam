defmodule SuperPi.Gateway.Router do
  @moduledoc """
  OpenAI-Compatible Upstream Inference HTTP Router (`REQ-GATEWAY-01`, `REQ-GATEWAY-02`).
  Allows OpenCode, Cursor, Aider, LibreChat, and other AI clients to treat Super-Pi-BEAM
  as an upstream inference provider and agent runtime.
  """

  use Plug.Router
  use Plug.ErrorHandler
  import Plug.Conn
  require Logger

  alias SuperPi.Conversation.Machine
  alias SuperPi.Durable.Storage
  alias SuperPi.Durable.Schemas.Conversation
  alias SuperPi.Harness
  alias SuperPi.Repo

  plug Plug.Logger, log: :debug
  plug :match
  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
  plug :dispatch

  def call(conn, opts) do
    try do
      super(conn, opts)
    rescue
      e in Plug.Parsers.ParseError ->
        send_json(conn, 400, %{
          "error" => %{
            "message" => "Bad Request: #{Exception.message(e)}",
            "type" => "invalid_request_error",
            "code" => "parse_error"
          }
        })

      e in Plug.Conn.WrapperError ->
        send_json(conn, 400, %{
          "error" => %{
            "message" => "Bad Request: #{Exception.message(e)}",
            "type" => "invalid_request_error",
            "code" => "invalid_request"
          }
        })
    end
  end

  @impl Plug.ErrorHandler
  def handle_errors(conn, %{kind: _kind, reason: reason, stack: _stack}) do
    send_json(conn, 400, %{
      "error" => %{
        "message" => "Bad Request: #{Exception.message(reason)}",
        "type" => "invalid_request_error",
        "code" => "invalid_request"
      }
    })
  end

  get "/" do
    send_json(conn, 200, %{
      "status" => "ok",
      "app" => "super-pi-beam",
      "version" => "0.1.0",
      "description" => "Super-Pi-BEAM OpenAI-Compatible Upstream Inference Gateway"
    })
  end

  get "/health" do
    send_json(conn, 200, %{"status" => "healthy"})
  end

  get "/v1/models" do
    now = System.system_time(:second)

    models =
      Harness.list()
      |> Enum.map(fn mod ->
        %{
          "id" => mod.id(),
          "object" => "model",
          "created" => now,
          "owned_by" => "super-pi",
          "permission" => [],
          "root" => mod.id(),
          "parent" => nil,
          "description" => mod.description()
        }
      end)

    send_json(conn, 200, %{"object" => "list", "data" => models})
  end

  post "/v1/chat/completions" do
    params = conn.body_params

    with :ok <- validate_chat_params(params) do
      model = Map.get(params, "model")
      messages = Map.get(params, "messages")
      stream? = Map.get(params, "stream") == true

      # Auxiliary background calls (e.g. OpenCode title generation) are handled
      # ephemerally so they never corrupt the session's active system prompt or profile.
      if title_request?(messages) do
        handle_title_generation(conn, messages, model, stream?)
      else
        harness = Harness.resolve(model)

        Logger.debug("[Gateway] 📥 Received POST /v1/chat/completions | model: #{model} (harness: #{harness.id()}) | stream: #{stream?} | messages: #{length(messages)}")

        # 1. Resolve or create durable conversation
        {conv_id, new_session?} = resolve_conversation(conn, params)

        # 2. Extract system prompt and configure agent profile via resolved harness
        system_sections = extract_system_sections(messages)
        agent_opts = [system_sections: system_sections]

        agent_opts =
          if Harness.harness?(model) do
            agent_opts
          else
            Keyword.put(agent_opts, :model, model)
          end

        agent_cfg = harness.agent_defaults(agent_opts)

        current_agent = SuperPi.Durable.Doc.snapshot("conversation", conv_id, "pi.agent") || %{}
        current_model = Map.get(current_agent, "model")

        if new_session? do
          Storage.configure_agent!(conv_id, agent_cfg)
          seed_prior_messages(conv_id, messages)
        else
          # If client switched model/harness, update durable pi.agent doc
          if current_model != Map.get(agent_cfg, "model") or Harness.harness?(model) do
            updated_agent = Map.merge(current_agent, agent_cfg)
            Storage.configure_agent!(conv_id, updated_agent)
          end
        end

        # 3. Extract the active user prompt
        user_prompt = extract_last_user_prompt(messages)

        Logger.debug("[Gateway] 💬 Active prompt for ##{conv_id}")

        # 4. Start or update conversation machine with harness extensions
        extensions = harness.extensions([])
        pid = ensure_machine_started!(conv_id, extensions)

        # 5. Handle Streaming vs Non-Streaming
        if stream? do
          handle_streaming_completion(conn, conv_id, pid, user_prompt, model)
        else
          handle_sync_completion(conn, conv_id, pid, user_prompt, model)
        end
      end
    else
      {:error, status, msg} ->
        send_json(conn, status, %{
          "error" => %{
            "message" => msg,
            "type" => "invalid_request_error",
            "code" => "invalid_params"
          }
        })
    end
  end

  match _ do
    send_json(conn, 404, %{
      "error" => %{
        "message" => "Endpoint not found: #{conn.request_path}",
        "type" => "invalid_request_error",
        "code" => "not_found"
      }
    })
  end

  # --- Internal Helpers ---

  defp validate_chat_params(params) when is_map(params) do
    model = Map.get(params, "model")
    messages = Map.get(params, "messages")

    cond do
      is_nil(model) or not is_binary(model) or model == "" ->
        {:error, 400, "Parameter 'model' is required and must be a string"}

      is_nil(messages) or not is_list(messages) ->
        {:error, 400, "Parameter 'messages' is required and must be an array"}

      not Enum.all?(messages, &is_map/1) ->
        {:error, 400, "Each item in 'messages' must be an object"}

      true ->
        :ok
    end
  end

  defp validate_chat_params(_), do: {:error, 400, "Request body must be a JSON object"}

  defp send_json(conn, status, data) do
    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(status, Jason.encode!(data))
  end

  def ensure_session_cache! do
    if :ets.whereis(:super_pi_gateway_sessions) == :undefined do
      try do
        :ets.new(:super_pi_gateway_sessions, [:named_table, :public, :set, read_concurrency: true])
      rescue
        _ -> :ok
      end
    end

    :ok
  end

  defp title_request?(messages) when is_list(messages) do
    has_system? = Enum.any?(messages, fn m -> Map.get(m, "role") == "system" end)

    system_title? =
      Enum.any?(messages, fn m ->
        Map.get(m, "role") == "system" and
          String.trim(String.downcase(extract_content_text(Map.get(m, "content", "")))) == "you are a title generator"
      end)

    user_title? =
      not has_system? and
        Enum.any?(messages, fn m ->
          Map.get(m, "role") == "user" and
            String.starts_with?(String.downcase(String.trim(extract_content_text(Map.get(m, "content", "")))), "generate a title")
        end)

    system_title? or user_title?
  end

  defp title_request?(_), do: false

  defp handle_title_generation(conn, messages, model, stream?) do
    cmpl_id = "chatcmpl-title-" <> Uniq.UUID.uuid7()
    now = System.system_time(:second)
    title_model = "gemini-3-flash-preview"

    title_text =
      if SuperPi.AI.GeminiClient.configured?() do
        system_sections = extract_system_sections(messages)

        user_prompt =
          messages
          |> Enum.reverse()
          |> Enum.find_value(fn m ->
            if Map.get(m, "role") == "user" do
              extract_content_text(Map.get(m, "content", ""))
            end
          end) || "Conversation Title"

        payload = %{
          model: title_model,
          messages: [%{"role" => "user", "content" => user_prompt}],
          system_sections: system_sections
        }

        case SuperPi.AI.GeminiClient.generate(payload) do
          {:ok, %{"content" => content}} ->
            content
            |> Enum.find_value(fn
              %{"type" => "text", "text" => t} -> t
              %{"text" => t} -> t
              _ -> nil
            end)
            |> case do
              nil -> "Chat Session"
              text ->
                text
                |> String.trim()
                |> String.trim("\"")
                |> String.slice(0, 60)
            end

          _ ->
            "Chat Session"
        end
      else
        "Chat Session"
      end

    usage_map = %{
      "prompt_tokens" => 0,
      "completion_tokens" => 0,
      "total_tokens" => 0
    }

    if stream? do
      conn =
        conn
        |> put_resp_header("content-type", "text/event-stream")
        |> put_resp_header("cache-control", "no-cache")
        |> put_resp_header("connection", "keep-alive")
        |> put_resp_header("x-accel-buffering", "no")
        |> send_chunked(200)

      first_chunk = %{
        "id" => cmpl_id,
        "object" => "chat.completion.chunk",
        "created" => now,
        "model" => model,
        "choices" => [%{"index" => 0, "delta" => %{"role" => "assistant", "content" => ""}, "finish_reason" => nil}]
      }

      delta_chunk = %{
        "id" => cmpl_id,
        "object" => "chat.completion.chunk",
        "created" => now,
        "model" => model,
        "choices" => [%{"index" => 0, "delta" => %{"content" => title_text}, "finish_reason" => nil}]
      }

      stop_chunk = %{
        "id" => cmpl_id,
        "object" => "chat.completion.chunk",
        "created" => now,
        "model" => model,
        "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}]
      }

      usage_chunk = %{
        "id" => cmpl_id,
        "object" => "chat.completion.chunk",
        "created" => now,
        "model" => model,
        "choices" => [],
        "usage" => usage_map
      }

      with {:ok, conn} <- chunk(conn, "data: " <> Jason.encode!(first_chunk) <> "\n\n"),
           {:ok, conn} <- chunk(conn, "data: " <> Jason.encode!(delta_chunk) <> "\n\n"),
           {:ok, conn} <- chunk(conn, "data: " <> Jason.encode!(stop_chunk) <> "\n\n"),
           {:ok, conn} <- chunk(conn, "data: " <> Jason.encode!(usage_chunk) <> "\n\n"),
           {:ok, conn} <- chunk(conn, "data: [DONE]\n\n") do
        conn
      else
        {:error, _} -> conn
      end
    else
      resp = %{
        "id" => cmpl_id,
        "object" => "chat.completion",
        "created" => now,
        "model" => model,
        "choices" => [
          %{
            "index" => 0,
            "message" => %{"role" => "assistant", "content" => title_text},
            "finish_reason" => "stop"
          }
        ],
        "usage" => usage_map
      }

      send_json(conn, 200, resp)
    end
  end

  defp resolve_conversation(conn, params) do
    ensure_session_cache!()

    session_id =
      case get_req_header(conn, "x-session-id") do
        [id | _] when id != "" -> id
        _ ->
          case get_req_header(conn, "session-id") do
            [id | _] when id != "" -> id
            _ -> Map.get(params, "session_id")
          end
      end

    header_conv_id =
      case get_req_header(conn, "x-conversation-id") do
        [id | _] when id != "" -> id
        _ -> Map.get(params, "conversation_id")
      end

    cond do
      session_id != nil ->
        SuperPi.Env.FileLock.with_lock("gateway_session", session_id, fn ->
          case :ets.lookup(:super_pi_gateway_sessions, session_id) do
            [{^session_id, conv_id}] ->
              Logger.info("[Gateway] 🔗 Mapped session '#{session_id}' to existing conversation ##{conv_id}")
              {conv_id, false}

            [] ->
              conv = Storage.create_conversation!(agent: %{})
              :ets.insert(:super_pi_gateway_sessions, {session_id, conv.id})
              Logger.info("[Gateway] 🆕 Mapped new session '#{session_id}' to conversation ##{conv.id}")
              {conv.id, true}
          end
        end)

      header_conv_id != nil ->
        case Integer.parse(to_string(header_conv_id)) do
          {int_id, ""} ->
            case Repo.get(Conversation, int_id) do
              %Conversation{} ->
                Logger.info("[Gateway] 🔗 Attached to existing conversation ##{int_id}")
                {int_id, false}

              nil ->
                conv = Storage.create_conversation!(agent: %{})
                Logger.info("[Gateway] 🆕 Created conversation ##{conv.id} (requested ##{int_id} not found)")
                {conv.id, true}
            end

          _ ->
            conv = Storage.create_conversation!(agent: %{})
            {conv.id, true}
        end

      true ->
        conv = Storage.create_conversation!(agent: %{})
        Logger.info("[Gateway] 🆕 Created new conversation ##{conv.id}")
        {conv.id, true}
    end
  end

  defp extract_system_sections(messages) when is_list(messages) do
    messages
    |> Enum.filter(fn m -> Map.get(m, "role") == "system" end)
    |> Enum.with_index(1)
    |> Enum.map(fn {m, idx} ->
      content = extract_content_text(Map.get(m, "content", ""))
      %{"id" => "system_#{idx}", "content" => content}
    end)
  end

  defp extract_system_sections(_), do: []

  defp seed_prior_messages(conv_id, messages) when is_list(messages) do
    last_user_idx =
      messages
      |> Enum.reverse()
      |> Enum.find_index(fn m -> Map.get(m, "role") == "user" end)

    case last_user_idx do
      nil ->
        :ok

      rev_idx ->
        skip_idx = length(messages) - 1 - rev_idx

        messages
        |> Enum.with_index()
        |> Enum.reject(fn {_m, idx} -> idx == skip_idx end)
        |> Enum.each(fn {m, _idx} ->
          role = Map.get(m, "role")

          case role do
            "user" ->
              content = extract_content_text(Map.get(m, "content", ""))
              if content != "" do
                Storage.append_entry!(conv_id, "pi.message", %{
                  "role" => "user",
                  "content" => [%{"type" => "text", "text" => content}]
                })
              end

            "assistant" ->
              content_raw = Map.get(m, "content")
              tool_calls = Map.get(m, "tool_calls")

              content_blocks =
                cond do
                  is_list(content_raw) -> content_raw
                  is_binary(content_raw) and content_raw != "" -> [%{"type" => "text", "text" => content_raw}]
                  true -> []
                end

              content_blocks =
                if is_list(tool_calls) do
                  Enum.reduce(tool_calls, content_blocks, fn tc, acc ->
                    func = Map.get(tc, "function", %{})
                    acc ++ [
                      %{
                        "type" => "tool_call",
                        "id" => Map.get(tc, "id"),
                        "name" => Map.get(func, "name"),
                        "arguments" => Map.get(func, "arguments")
                      }
                    ]
                  end)
                else
                  content_blocks
                end

              entry_data = %{
                "role" => "assistant",
                "content" => content_blocks
              }

              entry_data = if tool_calls, do: Map.put(entry_data, "tool_calls", tool_calls), else: entry_data
              Storage.append_entry!(conv_id, "pi.message", entry_data)

            "tool" ->
              Storage.append_entry!(conv_id, "pi.message", %{
                "role" => "tool",
                "tool_call_id" => Map.get(m, "tool_call_id"),
                "content" => extract_content_text(Map.get(m, "content", ""))
              })

            _ ->
              :ok
          end
        end)
    end
  end

  defp seed_prior_messages(_conv_id, _messages), do: :ok

  defp extract_last_user_prompt(messages) when is_list(messages) do
    last_user =
      messages
      |> Enum.reverse()
      |> Enum.find(fn m -> Map.get(m, "role") == "user" end)

    case last_user do
      nil -> "Hello"
      %{} = m -> extract_content_text(Map.get(m, "content", "Hello"))
    end
  end

  defp extract_last_user_prompt(_), do: "Hello"

  defp extract_content_text(content) when is_binary(content), do: content

  defp extract_content_text(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{"type" => "text", "text" => t} -> t
      %{"text" => t} -> t
      t when is_binary(t) -> t
      _ -> ""
    end)
    |> Enum.join("\n")
  end

  defp extract_content_text(_), do: ""

  defp ensure_machine_started!(conv_id, extensions) do
    case Registry.lookup(SuperPi.Registry, {:conversation_machine, conv_id}) do
      [{pid, _}] ->
        Machine.set_extensions(pid, extensions)
        pid

      [] ->
        case Process.whereis(SuperPi.MachineSupervisor) do
          nil ->
            {:ok, pid} = Machine.start_link(conversation_id: conv_id, extensions: extensions)
            pid

          _sup ->
            case DynamicSupervisor.start_child(SuperPi.MachineSupervisor, {Machine, conversation_id: conv_id, extensions: extensions}) do
              {:ok, pid} -> pid
              {:error, {:already_started, pid}} -> pid
            end
        end
    end
  end

  # --- Non-Streaming Execution ---

  defp handle_sync_completion(conn, conv_id, pid, user_prompt, model) do
    case safe_machine_submit(pid, user_prompt, mode: :queue, timeout: 120_000) do
      {:ok, assistant_msg} ->
        reply_text =
          case assistant_msg do
            :handled_by_extension -> ""
            _ -> extract_assistant_msg_text(assistant_msg)
          end

        cmpl_id = "chatcmpl-" <> Uniq.UUID.uuid7()
        now = System.system_time(:second)

        usage = if is_map(assistant_msg), do: Map.get(assistant_msg, "usage", %{}), else: %{}
        in_tok = Map.get(usage, "input_tokens", 0) || Map.get(usage, :input_tokens, 0) || 0
        out_tok = Map.get(usage, "output_tokens", 0) || Map.get(usage, :output_tokens, 0) || 0

        {prompt_tok, comp_tok} =
          if in_tok > 0 or out_tok > 0 do
            {in_tok, out_tok}
          else
            snap = SuperPi.Durable.Doc.snapshot("conversation", conv_id, "pi.usage") || %{}
            {Map.get(snap, "inputTokens", 0), Map.get(snap, "outputTokens", 0)}
          end

        resp = %{
          "id" => cmpl_id,
          "object" => "chat.completion",
          "created" => now,
          "model" => model,
          "choices" => [
            %{
              "index" => 0,
              "message" => %{
                "role" => "assistant",
                "content" => reply_text
              },
              "finish_reason" => "stop"
            }
          ],
          "usage" => %{
            "prompt_tokens" => prompt_tok,
            "completion_tokens" => comp_tok,
            "total_tokens" => prompt_tok + comp_tok
          }
        }

        send_json(conn, 200, resp)

      {:error, reason} ->
        send_json(conn, 500, %{
          "error" => %{
            "message" => "Agent execution failed: #{inspect(reason)}",
            "type" => "server_error",
            "code" => "execution_error"
          }
        })
    end
  end

  defp safe_machine_submit(pid, prompt, opts) do
    try do
      Machine.submit(pid, prompt, opts)
    catch
      :exit, reason -> {:error, reason}
    end
  end

  # --- Streaming Execution (Server-Sent Events) ---

  defp handle_streaming_completion(conn, conv_id, pid, user_prompt, model) do
    cmpl_id = "chatcmpl-" <> Uniq.UUID.uuid7()
    created = System.system_time(:second)

    # Ensure any prior subscription from keep-alive connection reuse is completely purged
    Phoenix.PubSub.unsubscribe(SuperPi.PubSub, "conversation:#{conv_id}")
    flush_stale_mailbox(conv_id)
    Phoenix.PubSub.subscribe(SuperPi.PubSub, "conversation:#{conv_id}")

    # Set SSE headers and initiate chunked response
    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    first_chunk = %{
      "id" => cmpl_id,
      "object" => "chat.completion.chunk",
      "created" => created,
      "model" => model,
      "choices" => [
        %{
          "index" => 0,
          "delta" => %{"role" => "assistant"},
          "finish_reason" => nil
        }
      ]
    }

    conn =
      case chunk(conn, "data: " <> Jason.encode!(first_chunk) <> "\n\n") do
        {:ok, updated_conn} -> updated_conn
        {:error, _} -> conn
      end

    # Launch turn asynchronously
    task =
      Task.Supervisor.async_nolink(SuperPi.ToolTaskSupervisor, fn ->
        safe_machine_submit(pid, user_prompt, mode: :queue, timeout: 300_000)
      end)

    try do
      stream_sse_loop(conn, conv_id, task.ref, cmpl_id, created, model, pid)
    after
      # Always unsubscribe immediately so subsequent turns on this connection never multiply deltas
      Phoenix.PubSub.unsubscribe(SuperPi.PubSub, "conversation:#{conv_id}")
      flush_stale_mailbox(conv_id)
    end
  end

  defp flush_stale_mailbox(conv_id) do
    receive do
      {:conversation_event, ^conv_id, _} -> flush_stale_mailbox(conv_id)
      {:conversation_state, ^conv_id, _} -> flush_stale_mailbox(conv_id)
    after
      0 -> :ok
    end
  end

  defp stream_sse_loop(conn, conv_id, task_ref, cmpl_id, created, model, pid) do
    receive do
      {:conversation_event, ^conv_id, %{"type" => "text_delta", "delta" => delta}} ->
        Logger.debug("[Gateway] ⚡ Turn ##{conv_id} text delta: #{inspect(delta)}")

        chunk_obj = %{
          "id" => cmpl_id,
          "object" => "chat.completion.chunk",
          "created" => created,
          "model" => model,
          "choices" => [
            %{
              "index" => 0,
              "delta" => %{"content" => delta},
              "finish_reason" => nil
            }
          ]
        }

        case chunk(conn, "data: " <> Jason.encode!(chunk_obj) <> "\n\n") do
          {:ok, updated_conn} ->
            stream_sse_loop(updated_conn, conv_id, task_ref, cmpl_id, created, model, pid)

          {:error, _} ->
            Machine.cancel(pid)
            conn
        end

      {:conversation_event, ^conv_id, %{"type" => "thinking_delta", "delta" => delta}} ->
        Logger.debug("[Gateway] 🤔 Turn ##{conv_id} thinking delta: #{inspect(delta)}")

        chunk_obj = %{
          "id" => cmpl_id,
          "object" => "chat.completion.chunk",
          "created" => created,
          "model" => model,
          "choices" => [
            %{
              "index" => 0,
              "delta" => %{"reasoning_content" => delta},
              "finish_reason" => nil
            }
          ]
        }

        case chunk(conn, "data: " <> Jason.encode!(chunk_obj) <> "\n\n") do
          {:ok, updated_conn} ->
            stream_sse_loop(updated_conn, conv_id, task_ref, cmpl_id, created, model, pid)

          {:error, _} ->
            Machine.cancel(pid)
            conn
        end

      {:conversation_event, ^conv_id, %{"type" => "tool_started", "name" => name} = ev} ->
        Logger.info("[Gateway] ⚙️  Turn ##{conv_id} tool starting: '#{name}'")
        raw_args = Map.get(ev, "args") || Map.get(ev, "arguments") || %{}

        arg_preview =
          case raw_args do
            %{"command" => cmd} -> "$ #{to_string(cmd)}\n"
            %{"path" => p} -> "#{to_string(p)}\n"
            %{"query" => q} -> "query: #{to_string(q)}\n"
            m when is_map(m) ->
              case Jason.encode(m) do
                {:ok, json} -> "#{json}\n"
                _ -> "\n"
              end
            other ->
              "#{to_string(other)}\n"
          end

        progress_text = "⚙️ Executing #{name}: #{arg_preview}"

        chunk_obj = %{
          "id" => cmpl_id,
          "object" => "chat.completion.chunk",
          "created" => created,
          "model" => model,
          "choices" => [
            %{
              "index" => 0,
              "delta" => %{"reasoning_content" => progress_text},
              "finish_reason" => nil
            }
          ]
        }

        case chunk(conn, "data: " <> Jason.encode!(chunk_obj) <> "\n\n") do
          {:ok, updated_conn} ->
            stream_sse_loop(updated_conn, conv_id, task_ref, cmpl_id, created, model, pid)

          {:error, _} ->
            Machine.cancel(pid)
            conn
        end

      {:conversation_event, ^conv_id, %{"type" => "tool_completed", "name" => name} = ev} ->
        err? = Map.get(ev, "is_error", false)
        status_label = if err?, do: "❌", else: "✅"
        out_raw = ev |> Map.get("output", "") |> to_string() |> String.trim()

        out_preview =
          if out_raw != "" do
            " -> " <> String.slice(out_raw, 0..80) <> (if String.length(out_raw) > 80, do: "...", else: "")
          else
            ""
          end

        progress_text = "#{status_label} #{name} completed#{out_preview}\n\n"

        chunk_obj = %{
          "id" => cmpl_id,
          "object" => "chat.completion.chunk",
          "created" => created,
          "model" => model,
          "choices" => [
            %{
              "index" => 0,
              "delta" => %{"reasoning_content" => progress_text},
              "finish_reason" => nil
            }
          ]
        }

        case chunk(conn, "data: " <> Jason.encode!(chunk_obj) <> "\n\n") do
          {:ok, updated_conn} ->
            stream_sse_loop(updated_conn, conv_id, task_ref, cmpl_id, created, model, pid)

          {:error, _} ->
            Machine.cancel(pid)
            conn
        end

      {^task_ref, {:ok, _result}} ->
        Process.demonitor(task_ref, [:flush])
        Logger.info("[Gateway] 🏁 Turn ##{conv_id} finished execution, emitting stop chunk")
        drain_and_finish_sse(conn, conv_id, cmpl_id, created, model)

      {^task_ref, {:error, reason}} ->
        Process.demonitor(task_ref, [:flush])
        Logger.warning("[Gateway] ⚠️ Turn ##{conv_id} error: #{inspect(reason)}")

        err_chunk = %{
          "id" => cmpl_id,
          "object" => "chat.completion.chunk",
          "created" => created,
          "model" => model,
          "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "error"}],
          "error" => %{"message" => "Turn error: #{inspect(reason)}", "type" => "turn_error"}
        }

        with {:ok, conn} <- chunk(conn, "data: " <> Jason.encode!(err_chunk) <> "\n\n"),
             {:ok, conn} <- chunk(conn, "data: [DONE]\n\n") do
          conn
        else
          {:error, _} -> conn
        end

      {:DOWN, ^task_ref, :process, _pid, reason} ->
        Logger.warning("[Gateway] ⚠️ Turn ##{conv_id} worker task terminated: #{inspect(reason)}")

        err_chunk = %{
          "id" => cmpl_id,
          "object" => "chat.completion.chunk",
          "created" => created,
          "model" => model,
          "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "error"}],
          "error" => %{"message" => "Worker crashed: #{inspect(reason)}", "type" => "turn_error"}
        }

        with {:ok, conn} <- chunk(conn, "data: " <> Jason.encode!(err_chunk) <> "\n\n"),
             {:ok, conn} <- chunk(conn, "data: [DONE]\n\n") do
          conn
        else
          {:error, _} -> conn
        end

      _other ->
        stream_sse_loop(conn, conv_id, task_ref, cmpl_id, created, model, pid)
    after
      300_000 ->
        Logger.warning("[Gateway] ⏱️ Turn ##{conv_id} hit 300s timeout, closing SSE stream")
        drain_and_finish_sse(conn, conv_id, cmpl_id, created, model)
    end
  end

  defp drain_and_finish_sse(conn, conv_id, cmpl_id, created, model) do
    # Drain any remaining deltas in mailbox
    conn = drain_mailbox_deltas(conn, conv_id, cmpl_id, created, model)

    snap = SuperPi.Durable.Doc.snapshot("conversation", conv_id, "pi.usage") || %{}
    prompt_tok = Map.get(snap, "lastTurnInputTokens", 0)
    comp_tok = Map.get(snap, "lastTurnOutputTokens", 0)

    usage_map = %{
      "prompt_tokens" => prompt_tok,
      "completion_tokens" => comp_tok,
      "total_tokens" => prompt_tok + comp_tok
    }

    stop_chunk = %{
      "id" => cmpl_id,
      "object" => "chat.completion.chunk",
      "created" => created,
      "model" => model,
      "choices" => [
        %{
          "index" => 0,
          "delta" => %{},
          "finish_reason" => "stop"
        }
      ]
    }

    usage_chunk = %{
      "id" => cmpl_id,
      "object" => "chat.completion.chunk",
      "created" => created,
      "model" => model,
      "choices" => [],
      "usage" => usage_map
    }

    with {:ok, conn} <- chunk(conn, "data: " <> Jason.encode!(stop_chunk) <> "\n\n"),
         {:ok, conn} <- chunk(conn, "data: " <> Jason.encode!(usage_chunk) <> "\n\n"),
         {:ok, conn} <- chunk(conn, "data: [DONE]\n\n") do
      conn
    else
      {:error, _} -> conn
    end
  end

  defp drain_mailbox_deltas(conn, conv_id, cmpl_id, created, model) do
    receive do
      {:conversation_event, ^conv_id, %{"type" => "text_delta", "delta" => delta}} ->
        chunk_obj = %{
          "id" => cmpl_id,
          "object" => "chat.completion.chunk",
          "created" => created,
          "model" => model,
          "choices" => [%{"index" => 0, "delta" => %{"content" => delta}, "finish_reason" => nil}]
        }

        case chunk(conn, "data: " <> Jason.encode!(chunk_obj) <> "\n\n") do
          {:ok, next_conn} -> drain_mailbox_deltas(next_conn, conv_id, cmpl_id, created, model)
          {:error, _} -> conn
        end

      {:conversation_event, ^conv_id, _} ->
        drain_mailbox_deltas(conn, conv_id, cmpl_id, created, model)
    after
      0 -> conn
    end
  end

  defp extract_assistant_msg_text(%{"content" => blocks}) when is_list(blocks) do
    blocks
    |> Enum.map(fn
      %{"type" => "text", "text" => t} -> t
      %{"text" => t} -> t
      t when is_binary(t) -> t
      _ -> ""
    end)
    |> Enum.join("")
  end

  defp extract_assistant_msg_text(%{content: blocks}) when is_list(blocks) do
    blocks
    |> Enum.map(fn
      %{"type" => "text", "text" => t} -> t
      %{"text" => t} -> t
      t when is_binary(t) -> t
      _ -> ""
    end)
    |> Enum.join("")
  end

  defp extract_assistant_msg_text(msg) when is_binary(msg), do: msg
  defp extract_assistant_msg_text(_), do: ""
end
