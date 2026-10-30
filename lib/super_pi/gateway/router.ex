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
  alias SuperPi.Auth
  alias SuperPi.Durable.Storage
  alias SuperPi.Gateway.Sessions
  alias SuperPi.Durable.Schemas.Conversation
  alias SuperPi.Harness
  alias SuperPi.Repo

  plug Plug.Logger, log: :debug
  plug :match
  plug :trace_request
  plug :authenticate
  plug :reject_when_draining
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

  # Prometheus text format. Behind the same authentication as the API.
  get "/metrics" do
    conn
    |> put_resp_content_type("text/plain; version=0.0.4")
    |> send_resp(200, SuperPi.Telemetry.scrape())
  end

  # Cluster members and where the conversation machines run. Behind the same authentication as the API.
  get "/cluster" do
    status = SuperPi.Cluster.status()
    names = fn nodes -> Enum.map(nodes, &Atom.to_string/1) end

    send_json(conn, 200, %{
      "self" => Atom.to_string(status.self),
      "strategy" => Atom.to_string(status.strategy),
      "connected_nodes" => names.(status.connected_nodes),
      "registry_members" => names.(status.registry_members),
      "supervisor_members" => names.(status.supervisor_members),
      "machines_per_node" => Map.new(status.machines_per_node, fn {n, c} -> {Atom.to_string(n), c} end),
      "machine_count" => status.machine_count,
      "machine_supervision" => Atom.to_string(status.machine_supervision),
      "accepting" => status.accepting?,
      "db_adapter" => inspect(status.db_adapter)
    })
  end

  # Readiness: 503 while the node drains (SIGTERM), so a load balancer stops sending it traffic.
  get "/ready" do
    if SuperPi.Drain.accepting?(),
      do: send_json(conn, 200, %{"status" => "ready"}),
      else: send_json(conn, 503, %{"status" => "shutting_down"})
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

    # Models that a configured provider serves are passed through, so they are valid `model` values.
    provider_models =
      SuperPi.AI.Providers.catalog()
      |> Enum.filter(& &1["available"])
      |> Enum.map(fn m ->
        %{
          "id" => m["id"],
          "object" => "model",
          "created" => now,
          "owned_by" => m["provider"],
          "permission" => [],
          "root" => m["id"],
          "parent" => nil,
          "description" => m["label"]
        }
      end)

    send_json(conn, 200, %{"object" => "list", "data" => models ++ provider_models})
  end

  post "/v1/chat/completions" do
    params = conn.body_params

    with :ok <- validate_chat_params(params),
         :ok <- validate_model(params) do
      model = Map.get(params, "model")
      messages = Map.get(params, "messages")
      stream? = Map.get(params, "stream") == true

      # Auxiliary background calls (e.g. OpenCode title generation) are handled
      # ephemerally so they never corrupt the session's active system prompt or profile.
      if title_request?(messages) do
        handle_title_generation(conn, messages, model, stream?)
      else
        harness = if Harness.harness?(model), do: Harness.resolve(model), else: Harness.default()
        requested_mode = requested_mode(conn, params)

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

        agent_cfg =
          harness.agent_defaults(agent_opts)
          |> SuperPi.Plugins.Permissions.apply_remote_mode(requested_mode)

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

          # A request that names a mode changes it for this session, within the ceiling.
          if requested_mode do
            Storage.configure_agent!(conv_id, %{"executionMode" => Map.fetch!(agent_cfg, "executionMode")})
          end
        end

        # 3. Extract the active user prompt
        user_prompt = extract_last_user_prompt(messages)

        Logger.debug("[Gateway] 💬 Active prompt for ##{conv_id}")

        # 4. Start or update conversation machine with harness extensions
        extensions = Harness.remote_extensions(harness)

        pid = SuperPi.Conversation.Locator.ensure_started!(conv_id, extensions, set_extensions: true)

        # 5. Handle Streaming vs Non-Streaming
        if stream? do
          handle_streaming_completion(conn, conv_id, pid, user_prompt, model)
        else
          handle_sync_completion(conn, conv_id, pid, user_prompt, model)
        end
      end
    else
      {:error, status, code, msg} ->
        send_json(conn, status, %{
          "error" => %{"message" => msg, "type" => "invalid_request_error", "code" => code}
        })

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

  # Mode that the caller asks for: `x-super-pi-mode` header or `execution_mode` body field.
  defp requested_mode(conn, params) do
    case Plug.Conn.get_req_header(conn, "x-super-pi-mode") do
      [mode | _] -> mode
      [] -> Map.get(params, "execution_mode")
    end
  end

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

      bad_id = invalid_tool_call_arguments(messages) ->
        {:error, 400, "invalid_tool_call_arguments",
         "messages[].tool_calls[].function.arguments of tool call '#{bad_id}' is not a JSON object string"}

      true ->
        :ok
    end
  end

  defp validate_chat_params(_), do: {:error, 400, "Request body must be a JSON object"}

  # The id of the first assistant tool call whose arguments do not decode to a JSON object, or nil.
  defp invalid_tool_call_arguments(messages) do
    Enum.find_value(messages, fn
      %{"role" => "assistant", "tool_calls" => calls} when is_list(calls) ->
        Enum.find_value(calls, fn tc ->
          args = get_in(tc, ["function", "arguments"])
          if match?({:ok, _}, decode_tool_arguments(args)), do: nil, else: Map.get(tc, "id") || "unknown"
        end)

      _ ->
        nil
    end)
  end

  # OpenAI sends tool call arguments as a JSON string. Stored arguments are always a map.
  defp decode_tool_arguments(args) when is_map(args), do: {:ok, args}
  defp decode_tool_arguments(nil), do: {:ok, %{}}

  defp decode_tool_arguments(args) when is_binary(args) do
    if String.trim(args) == "" do
      {:ok, %{}}
    else
      case Jason.decode(args) do
        {:ok, %{} = decoded} -> {:ok, decoded}
        _ -> :error
      end
    end
  end

  defp decode_tool_arguments(_), do: :error

  defp send_json(conn, status, data) do
    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(status, Jason.encode!(data))
  end

  @doc false
  def ensure_session_cache!, do: :ok

  defp title_request?(messages) when is_list(messages) do
    system_title? =
      Enum.any?(messages, fn m ->
        Map.get(m, "role") == "system" and
          m
          |> Map.get("content", "")
          |> extract_content_text()
          |> String.downcase()
          |> String.trim()
          |> String.starts_with?("you are a title generator")
      end)

    system_title?
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

  # A draining node takes no new turns. The client retries and reaches another node.
  defp reject_when_draining(%Plug.Conn{method: "POST", request_path: "/v1/chat/completions"} = conn, _opts) do
    if SuperPi.Drain.accepting?() do
      conn
    else
      conn
      |> put_resp_header("retry-after", "1")
      |> send_json(503, %{
        "error" => %{
          "message" => "This node is shutting down. Retry the request.",
          "type" => "server_error",
          "code" => "shutting_down"
        }
      })
      |> halt()
    end
  end

  defp reject_when_draining(conn, _opts), do: conn

  # One span per request. A streamed response ends the span when the headers are sent.
  defp trace_request(conn, _opts) do
    handle =
      SuperPi.Telemetry.start_span("super_pi.gateway.request", %{
        "http.request.method" => conn.method,
        "url.path" => conn.request_path
      })

    register_before_send(conn, fn conn ->
      status = conn.status || 0
      outcome = if status >= 500, do: {:error, "HTTP #{status}"}, else: :ok
      SuperPi.Telemetry.stop_span(handle, outcome, %{"http.response.status_code" => status})
      conn
    end)
  end

  # A model is a harness id (a virtual model that selects an agent persona) or a name that
  # a registered provider serves (passed through to that provider). Anything else is a
  # client error, as in other OpenAI-compatible gateways, so a typo never silently runs
  # some other model. Auxiliary title requests are not checked.
  defp validate_model(%{"model" => model, "messages" => messages}) when is_binary(model) and is_list(messages) do
    cond do
      title_request?(messages) ->
        :ok

      Harness.harness?(model) ->
        :ok

      true ->
        case SuperPi.AI.Providers.resolve(model) do
          {:ok, _provider, _model} ->
            :ok

          {:error, {:no_provider, _}} ->
            {:error, 404, "model_not_found",
             "The model `#{model}` does not exist or no provider serves it. List models with GET /v1/models."}

          {:error, {:not_configured, provider}} ->
            {:error, 503, "provider_not_configured",
             "Provider `#{provider}` is not configured for model `#{model}` (missing API key or settings)."}
        end
    end
  end

  defp validate_model(_params), do: :ok

  # `/` and `/health` stay open so probes work. Everything else needs a configured token
  # (`SuperPi.Auth`). With no tokens configured the gateway is open, which is safe only on
  # loopback; `SuperPi.Gateway.Server` refuses a non-loopback bind without a token.
  defp authenticate(%Plug.Conn{request_path: path} = conn, _opts) when path in ["/", "/health", "/ready"] do
    assign(conn, :principal, Auth.anonymous())
  end

  defp authenticate(conn, _opts) do
    token =
      case get_req_header(conn, "authorization") do
        [header | _] -> Auth.bearer_token(header)
        _ -> nil
      end

    case Auth.authenticate(token) do
      {:ok, principal} ->
        assign(conn, :principal, principal)

      :error ->
        conn
        |> put_resp_header("www-authenticate", "Bearer")
        |> send_json(401, %{
          "error" => %{
            "message" => "Invalid or missing API key. Send `Authorization: Bearer <key>`.",
            "type" => "invalid_request_error",
            "code" => "invalid_api_key"
          }
        })
        |> halt()
    end
  end

  defp new_conversation(principal) do
    Storage.create_conversation!(agent: %{}, owner: principal)
  end

  defp resolve_conversation(conn, params) do
    principal = conn.assigns[:principal] || Auth.anonymous()

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
        # Sessions are per principal: two clients that pick the same id do not share a conversation.
        # Stored in the database (`SuperPi.Gateway.Sessions`): survives a restart and is shared by
        # every node. The local lock only avoids creating a conversation twice on this node.
        :global.trans({{:gateway_session, {principal, session_id}}, self()}, fn ->
          {conv_id, new?} =
            Sessions.fetch_or_create(principal, session_id, fn -> new_conversation(principal) end)

          if new? do
            Logger.info("[Gateway] 🆕 Mapped new session '#{session_id}' to conversation ##{conv_id}")
          else
            Logger.info("[Gateway] 🔗 Mapped session '#{session_id}' to existing conversation ##{conv_id}")
          end

          {conv_id, new?}
        end, [node()], :infinity)

      header_conv_id != nil ->
        case Integer.parse(to_string(header_conv_id)) do
          {int_id, ""} ->
            # A conversation owned by another principal is answered like a missing one.
            case Repo.get(Conversation, int_id) do
              %Conversation{} ->
                if Auth.authorized?(int_id, principal) do
                  Logger.info("[Gateway] 🔗 Attached to existing conversation ##{int_id}")
                  {int_id, false}
                else
                  conv = new_conversation(principal)
                  Logger.info("[Gateway] 🆕 Created conversation ##{conv.id} (requested ##{int_id} not available)")
                  {conv.id, true}
                end

              nil ->
                conv = new_conversation(principal)
                Logger.info("[Gateway] 🆕 Created conversation ##{conv.id} (requested ##{int_id} not found)")
                {conv.id, true}
            end

          _ ->
            conv = new_conversation(principal)
            {conv.id, true}
        end

      true ->
        conv = new_conversation(principal)
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
                    # Checked in `validate_chat_params/1`.
                    {:ok, args} = decode_tool_arguments(Map.get(func, "arguments"))

                    acc ++ [
                      %{
                        "type" => "tool_call",
                        "id" => Map.get(tc, "id"),
                        "name" => Map.get(func, "name"),
                        "arguments" => args
                      }
                    ]
                  end)
                else
                  content_blocks
                end

              Storage.append_entry!(conv_id, "pi.message", %{"role" => "assistant", "content" => content_blocks})

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

  # --- Non-Streaming Execution ---

  defp handle_sync_completion(conn, conv_id, pid, user_prompt, model) do
    case Machine.safe_submit(pid, user_prompt, mode: :queue, timeout: 120_000, otel_ctx: SuperPi.Telemetry.current_ctx()) do
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

  # --- Streaming Execution (Server-Sent Events) ---

  defp handle_streaming_completion(conn, conv_id, pid, user_prompt, model) do
    cmpl_id = "chatcmpl-" <> Uniq.UUID.uuid7()
    created = System.system_time(:second)

    # Ensure any prior subscription from keep-alive connection reuse is completely purged
    Phoenix.PubSub.unsubscribe(SuperPi.PubSub, "conversation:#{conv_id}")
    flush_stale_mailbox(conv_id)
    Phoenix.PubSub.subscribe(SuperPi.PubSub, "conversation:#{conv_id}")

    # The request span ends when the headers are sent, so capture its context first: the turn
    # span must be its child.
    otel_ctx = SuperPi.Telemetry.current_ctx()

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
        Machine.safe_submit(pid, user_prompt, mode: :queue, timeout: 300_000, otel_ctx: otel_ctx)
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
            %{"command" => cmd} when is_binary(cmd) -> "$ #{cmd}\n"
            %{"path" => p} when is_binary(p) -> "#{p}\n"
            %{"query" => q} when is_binary(q) -> "query: #{q}\n"
            m when is_map(m) ->
              case Jason.encode(m) do
                {:ok, json} -> "#{json}\n"
                _ -> "#{inspect(m)}\n"
              end
            other ->
              case Jason.encode(other) do
                {:ok, json} -> "#{json}\n"
                _ -> "#{inspect(other)}\n"
              end
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
        out_raw =
          case Map.get(ev, "output", "") do
            s when is_binary(s) -> s
            other ->
              case Jason.encode(other) do
                {:ok, json} -> json
                _ -> inspect(other)
              end
          end
          |> String.trim()

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
