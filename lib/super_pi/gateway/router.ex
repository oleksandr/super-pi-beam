defmodule SuperPi.Gateway.Router do
  @moduledoc """
  OpenAI-Compatible Upstream Inference HTTP Router (`REQ-GATEWAY-01`, `REQ-GATEWAY-02`).
  Allows OpenCode, Cursor, Aider, LibreChat, and other AI clients to treat Super-Pi-BEAM
  as an upstream inference provider and agent runtime.
  """

  use Plug.Router
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
    params = conn.body_params || %{}
    model = Map.get(params, "model", "super-pi-agent")
    messages = Map.get(params, "messages", [])
    stream? = Map.get(params, "stream", false)

    harness = Harness.resolve(model)

    Logger.info("[Gateway] 📥 Received POST /v1/chat/completions | model: #{model} (harness: #{harness.id()}) | stream: #{stream?} | messages: #{length(messages)}")

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

    if new_session? do
      Storage.configure_agent!(conv_id, agent_cfg)
      seed_prior_messages(conv_id, messages)
    end

    # 3. Extract the active user prompt
    user_prompt = extract_last_user_prompt(messages)
    prompt_preview =
      if String.length(user_prompt) > 80 do
        String.slice(user_prompt, 0..80) <> "..."
      else
        user_prompt
      end

    Logger.info("[Gateway] 💬 Active prompt for ##{conv_id}: #{inspect(prompt_preview)}")

    # 4. Start conversation machine with harness extensions
    extensions = harness.extensions([])
    pid = ensure_machine_started!(conv_id, extensions)

    # 5. Handle Streaming vs Non-Streaming
    if stream? do
      handle_streaming_completion(conn, conv_id, pid, user_prompt, model)
    else
      handle_sync_completion(conn, pid, user_prompt, model)
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

  defp resolve_conversation(conn, _params) do
    ensure_session_cache!()

    header_conv_id =
      case get_req_header(conn, "x-conversation-id") do
        [id | _] when id != "" -> id
        _ ->
          case get_req_header(conn, "x-session-id") do
            [id | _] when id != "" -> id
            _ -> nil
          end
      end

    case header_conv_id do
      nil ->
        conv = Storage.create_conversation!(agent: %{})
        Logger.info("[Gateway] 🆕 Created new conversation ##{conv.id}")
        {conv.id, true}

      id_str ->
        case Integer.parse(id_str) do
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
            case :ets.lookup(:super_pi_gateway_sessions, id_str) do
              [{^id_str, existing_conv_id}] ->
                Logger.info("[Gateway] 🔗 Mapped session '#{id_str}' to existing conversation ##{existing_conv_id}")
                {existing_conv_id, false}

              [] ->
                conv = Storage.create_conversation!(agent: %{})
                :ets.insert(:super_pi_gateway_sessions, {id_str, conv.id})
                Logger.info("[Gateway] 🆕 Mapped new session '#{id_str}' to conversation ##{conv.id}")
                {conv.id, true}
            end
        end
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

  defp seed_prior_messages(conv_id, messages) when is_list(messages) and length(messages) > 1 do
    # All messages except the last user turn are recorded as prior conversational context
    prior = Enum.slice(messages, 0..-2//1)

    Enum.each(prior, fn m ->
      role = Map.get(m, "role")
      content = extract_content_text(Map.get(m, "content", ""))

      if role in ["user", "assistant"] and content != "" do
        Storage.append_entry!(conv_id, "pi.message", %{
          "role" => role,
          "content" => [%{"type" => "text", "text" => content}]
        })
      end
    end)
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
        pid

      [] ->
        {:ok, pid} = Machine.start_link(conversation_id: conv_id, extensions: extensions)
        pid
    end
  end

  # --- Non-Streaming Execution ---

  defp handle_sync_completion(conn, pid, user_prompt, model) do
    case Machine.submit(pid, user_prompt, mode: :queue, timeout: 120_000) do
      {:ok, assistant_msg} ->
        reply_text = extract_assistant_msg_text(assistant_msg)
        cmpl_id = "chatcmpl-" <> Uniq.UUID.uuid7()
        now = System.system_time(:second)

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
            "prompt_tokens" => 20,
            "completion_tokens" => 20,
            "total_tokens" => 40
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

  # --- Streaming Execution (Server-Sent Events) ---

  defp handle_streaming_completion(conn, conv_id, pid, user_prompt, model) do
    cmpl_id = "chatcmpl-" <> Uniq.UUID.uuid7()
    created = System.system_time(:second)

    # Subscribe current handler to turn events
    Phoenix.PubSub.subscribe(SuperPi.PubSub, "conversation:#{conv_id}")

    # Set SSE headers and initiate chunked response
    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    # Launch turn asynchronously
    task =
      Task.Supervisor.async_nolink(SuperPi.ToolTaskSupervisor, fn ->
        Machine.submit(pid, user_prompt, mode: :queue, timeout: 300_000)
      end)

    stream_sse_loop(conn, conv_id, task.ref, cmpl_id, created, model)
  end

  defp stream_sse_loop(conn, conv_id, task_ref, cmpl_id, created, model) do
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
            stream_sse_loop(updated_conn, conv_id, task_ref, cmpl_id, created, model)

          {:error, _} ->
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
            stream_sse_loop(updated_conn, conv_id, task_ref, cmpl_id, created, model)

          {:error, _} ->
            conn
        end

      {:conversation_event, ^conv_id, %{"type" => "tool_started", "name" => name} = ev} ->
        args = Map.get(ev, "args", %{})
        Logger.info("[Gateway] ⚙️  Turn ##{conv_id} tool starting: '#{name}' (args: #{inspect(args)})")

        notice = "\n\n> ⚙️ *Executing tool `#{name}`...*\n\n"

        chunk_obj = %{
          "id" => cmpl_id,
          "object" => "chat.completion.chunk",
          "created" => created,
          "model" => model,
          "choices" => [
            %{
              "index" => 0,
              "delta" => %{"content" => notice},
              "finish_reason" => nil
            }
          ]
        }

        case chunk(conn, "data: " <> Jason.encode!(chunk_obj) <> "\n\n") do
          {:ok, updated_conn} ->
            stream_sse_loop(updated_conn, conv_id, task_ref, cmpl_id, created, model)

          {:error, _} ->
            conn
        end

      {:conversation_event, ^conv_id, %{"type" => "tool_completed", "name" => name} = ev} ->
        err? = Map.get(ev, "is_error", false)
        status_label = if err?, do: "❌ ERROR", else: "✅ SUCCESS"
        out_preview = ev |> Map.get("output", "") |> to_string() |> String.slice(0..100)
        Logger.info("[Gateway] #{status_label} Turn ##{conv_id} tool '#{name}' completed (output: #{inspect(out_preview)}...)")
        stream_sse_loop(conn, conv_id, task_ref, cmpl_id, created, model)

      {^task_ref, _result} ->
        Process.demonitor(task_ref, [:flush])
        Logger.info("[Gateway] 🏁 Turn ##{conv_id} finished execution, emitting stop chunk")
        drain_and_finish_sse(conn, conv_id, cmpl_id, created, model)

      {:DOWN, ^task_ref, :process, _pid, reason} ->
        Logger.warning("[Gateway] ⚠️ Turn ##{conv_id} worker task terminated: #{inspect(reason)}")
        drain_and_finish_sse(conn, conv_id, cmpl_id, created, model)

      _other ->
        stream_sse_loop(conn, conv_id, task_ref, cmpl_id, created, model)
    after
      300_000 ->
        Logger.warning("[Gateway] ⏱️ Turn ##{conv_id} hit 300s timeout, closing SSE stream")
        drain_and_finish_sse(conn, conv_id, cmpl_id, created, model)
    end
  end

  defp drain_and_finish_sse(conn, conv_id, cmpl_id, created, model) do
    # Drain any remaining deltas in mailbox
    conn = drain_mailbox_deltas(conn, conv_id, cmpl_id, created, model)

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

    case chunk(conn, "data: " <> Jason.encode!(stop_chunk) <> "\n\n") do
      {:ok, conn} ->
        case chunk(conn, "data: [DONE]\n\n") do
          {:ok, final_conn} -> final_conn
          {:error, _} -> conn
        end

      {:error, _} ->
        conn
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
          {:ok, updated_conn} ->
            drain_mailbox_deltas(updated_conn, conv_id, cmpl_id, created, model)

          {:error, _} ->
            conn
        end
    after
      20 -> conn
    end
  end

  defp extract_assistant_msg_text(%{"content" => list}) when is_list(list) do
    list
    |> Enum.map(fn
      %{"type" => "text", "text" => t} -> t
      %{"text" => t} -> t
      t when is_binary(t) -> t
      _ -> ""
    end)
    |> Enum.join("")
  end

  defp extract_assistant_msg_text(%{"content" => text}) when is_binary(text), do: text
  defp extract_assistant_msg_text(other), do: inspect(other)
end
