defmodule SuperPi.MCP.Server do
  @moduledoc """
  Model Context Protocol (MCP) server (`REQ-MCP-01`..`REQ-MCP-04`), over `stdio` here and over
  Streamable HTTP in `SuperPi.MCP.HTTPPlug`.

  Allows any MCP-compliant host (OpenCode, Claude Desktop, Cursor, Zed, Continue.dev)
  to connect to Super-Pi-BEAM as a standard tool and context provider.

  `handle_mcp_line/2` is pure: it takes one JSON-RPC message and the connection state and returns
  the reply and the next state. The transports only move lines (stdio) or request bodies (HTTP).

  ## Protocol versions

  `initialize` answers the client's `protocolVersion` when the server speaks it (`2025-06-18`,
  `2025-03-26`, `2024-11-05`), else the newest. The requested version is logged at debug level,
  which is how to find out what a host asks for. `2026-07-28` is not supported: it replaces
  elicitation, sampling and roots with a different round trip.

  ## Supported Methods
  - `initialize` - Handshake declaring tool, resource, and prompt capabilities.
  - `notifications/initialized` - Post-handshake acknowledgment.
  - `ping` - Heartbeat check.
  - `tools/list` - The eight tools with JSON Schema and annotations (`readOnlyHint`,
    `destructiveHint`, `idempotentHint`, `openWorldHint`), which hosts use to decide what to
    approve without asking.
  - `tools/call` - Runs a tool through the permission policy of the connection's harness. The
    result carries `content` (text) and, when the tool returns structured data, `structuredContent`.
  - `prompts/list` & `prompts/get` - One prompt per harness (`SuperPi.Harness.list/0`), plus the
    `plan_architecture` alias.
  - `resources/list`, `resources/read` - The workspace context, the tool loadout and the
    conversations that this connection started.
  - `resources/templates/list` - `superpi://conversation/{id}/transcript`, which `resources/read`
    answers with the conversation transcript as JSON lines (the compact form that
    `SuperPi.Plugins.TranscriptLogger` writes). A conversation of another principal is not found.

  ## Choosing a harness

  `harness_task` takes a `harness` argument (an id from `Harness.list/0`) and runs the task in
  that harness. Direct tool calls (`read`, `bash` ...) run under the connection's harness: the
  state key `:harness`, else `config :super_pi, :mcp_harness`, else `Harness.default/0`. The
  workspace is the first of `SuperPi.Discovery.default_workspace_paths/0`.

  Tools run in the mode that `SuperPi.Plugins.Permissions.apply_remote_mode/2` allows a remote
  caller. State keys: `:harness`, `:principal` (an `SuperPi.Auth` principal, default anonymous).
  """

  alias SuperPi.Auth
  alias SuperPi.Discovery
  alias SuperPi.Durable.Storage
  alias SuperPi.Harness
  alias SuperPi.Plugins.TranscriptLogger
  alias SuperPi.Tools

  require Logger

  # Newest first. The ceiling is 2025-06-18: 2026-07-28 replaces elicitation, sampling and roots
  # with a different round trip, so no mainstream host negotiates it yet.
  @supported_versions ["2025-06-18", "2025-03-26", "2024-11-05"]
  @transcript_mime "application/x-ndjson"
  @server_name "super-pi-beam"
  @server_version "1.0.0"

  @doc """
  Runs the MCP server over standard input and output in a blocking loop.
  """
  def run_stdio do
    IO.stream(:stdio, :line)
    |> Enum.reduce_while(%{}, fn line, state ->
      trimmed = String.trim(line)

      if trimmed == "" do
        {:cont, state}
      else
        case handle_mcp_line(trimmed, state) do
          {:reply, reply_map, next_state} ->
            output = Jason.encode!(reply_map)
            IO.puts(:stdio, output)
            {:cont, next_state}

          {:noreply, next_state} ->
            {:cont, next_state}

          {:stop, _reason, next_state} ->
            {:halt, next_state}
        end
      end
    end)
  end

  @doc """
  Handles a single raw MCP JSON-RPC 2.0 payload string.
  Pure handler suitable for unit tests and property testing.
  """
  def handle_mcp_line(raw_json, state) when is_binary(raw_json) and is_map(state) do
    case Jason.decode(raw_json) do
      {:ok, %{"jsonrpc" => "2.0", "method" => method} = req} ->
        id = Map.get(req, "id")
        params = Map.get(req, "params", %{})
        dispatch(method, params, id, state)

      {:ok, _other} ->
        {:reply, jsonrpc_error(nil, -32600, "Invalid Request"), state}

      {:error, _err} ->
        {:reply, jsonrpc_error(nil, -32700, "Parse error"), state}
    end
  end

  # --- Method Dispatch ---

  defp dispatch("initialize", params, id, state) when not is_map(params) do
    {:reply, jsonrpc_error(id, -32602, "Invalid params: initialize requires an object"), state}
  end

  defp dispatch("initialize", params, id, state) do
    client_info = Map.get(params, "clientInfo", %{})
    requested = Map.get(params, "protocolVersion")
    version = negotiate_version(requested)

    # Which version hosts really ask for is not recorded anywhere else.
    Logger.debug(
      "[MCP] initialize from #{inspect(Map.get(client_info, "name"))}: requested #{inspect(requested)}, answering #{version}"
    )

    reply =
      jsonrpc_result(id, %{
        "protocolVersion" => version,
        "capabilities" => %{
          "tools" => %{"listChanged" => true},
          "resources" => %{"subscribe" => false, "listChanged" => false},
          "prompts" => %{"listChanged" => false}
        },
        "serverInfo" => %{
          "name" => @server_name,
          "version" => @server_version
        }
      })

    next_state =
      state |> Map.put(:client_info, client_info) |> Map.put(:protocol_version, version)

    {:reply, reply, next_state}
  end

  defp dispatch("notifications/" <> _notif, _params, _id, state) do
    {:noreply, state}
  end

  defp dispatch("ping", _params, id, state) do
    {:reply, jsonrpc_result(id, %{}), state}
  end

  defp dispatch("exit", _params, _id, state) do
    {:stop, :normal, state}
  end

  defp dispatch("tools/list", params, id, state) do
    if is_map(params) and Map.get(params, "cursor") != nil do
      {:reply, jsonrpc_error(id, -32602, "Invalid cursor"), state}
    else
      tools = tool_definitions()
      {:reply, jsonrpc_result(id, %{"tools" => tools}), state}
    end
  end

  defp dispatch("tools/call", params, id, state) when not is_map(params) do
    {:reply, jsonrpc_error(id, -32602, "Invalid params: tools/call requires an object"), state}
  end

  defp dispatch("tools/call", %{"name" => name} = params, id, state) when is_binary(name) do
    args = Map.get(params, "arguments", %{})

    if not is_map(args) do
      reply =
        jsonrpc_result(id, %{
          "content" => [
            %{"type" => "text", "text" => "Invalid arguments: arguments must be an object"}
          ],
          "isError" => true
        })

      {:reply, reply, state}
    else
      {result, state} =
        case name do
          "harness_task" ->
            harness_task(args, state)

          other ->
            # Tools run through the connection harness's `before_tool` pipeline (permissions,
            # protected paths), the same as a model-issued call.
            case authorize_tool(other, args, state) do
              {{:ok, final_args}, state} ->
                {Tools.execute(other, final_args), state}

              {{:blocked, reason}, state} ->
                {%{"output" => "Blocked: #{reason}", "is_error" => true}, state}
            end
        end

      {:reply, jsonrpc_result(id, call_result(result)), state}
    end
  end

  defp dispatch("tools/call", params, id, state) when is_map(params) do
    case Map.get(params, "name") do
      nil ->
        {:reply, jsonrpc_error(id, -32602, "Missing required parameter 'name'"), state}

      _not_string ->
        reply =
          jsonrpc_result(id, %{
            "content" => [%{"type" => "text", "text" => "Tool name must be a string"}],
            "isError" => true
          })

        {:reply, reply, state}
    end
  end

  defp dispatch("resources/list", params, id, state) do
    if is_map(params) and Map.get(params, "cursor") != nil do
      {:reply, jsonrpc_error(id, -32602, "Invalid cursor"), state}
    else
      resources = [
        %{
          "uri" => "superpi://workspace/context",
          "name" => "Super-Pi Active Context",
          "description" => "Current 10-rule derived conversation context and system prompt",
          "mimeType" => "application/json"
        },
        %{
          "uri" => "superpi://workspace/tools",
          "name" => "Super-Pi Active Tool Loadouts",
          "description" => "Active tool declarations and exposure modes",
          "mimeType" => "application/json"
        }
      ]

      # The conversations this connection started, so a host finds their transcripts.
      conversations =
        for conv_id <- Map.get(state, :conversations, []) do
          %{
            "uri" => transcript_uri(conv_id),
            "name" => "Conversation #{conv_id} transcript",
            "description" => "Transcript of a harness_task conversation, as JSON lines",
            "mimeType" => @transcript_mime
          }
        end

      {:reply, jsonrpc_result(id, %{"resources" => resources ++ conversations}), state}
    end
  end

  defp dispatch("resources/templates/list", params, id, state) do
    if is_map(params) and Map.get(params, "cursor") != nil do
      {:reply, jsonrpc_error(id, -32602, "Invalid cursor"), state}
    else
      templates = [
        %{
          "uriTemplate" => "superpi://conversation/{id}/transcript",
          "name" => "Conversation transcript",
          "description" =>
            "The transcript of a conversation as JSON lines, one step per line. The id is the conversation_id that harness_task returns.",
          "mimeType" => @transcript_mime
        }
      ]

      {:reply, jsonrpc_result(id, %{"resourceTemplates" => templates}), state}
    end
  end

  defp dispatch("resources/read", params, id, state) when not is_map(params) do
    {:reply, jsonrpc_error(id, -32602, "Invalid params: resources/read requires an object"),
     state}
  end

  defp dispatch("resources/read", %{"uri" => uri}, id, state) when is_binary(uri) do
    case uri do
      "superpi://workspace/context" ->
        content =
          Jason.encode!(%{
            "status" => "ready",
            "working_directory" => workspace_root(),
            "workspace_paths" => Discovery.default_workspace_paths(),
            "harness" => state |> connection_harness() |> then(& &1.id()),
            "tools" => Tools.active_llm_tools()
          })

        reply =
          jsonrpc_result(id, %{
            "contents" => [
              %{
                "uri" => uri,
                "mimeType" => "application/json",
                "text" => content
              }
            ]
          })

        {:reply, reply, state}

      "superpi://workspace/tools" ->
        content = Jason.encode!(Tools.active_llm_tools())

        reply =
          jsonrpc_result(id, %{
            "contents" => [
              %{
                "uri" => uri,
                "mimeType" => "application/json",
                "text" => content
              }
            ]
          })

        {:reply, reply, state}

      _other ->
        case read_transcript(uri, state) do
          {:ok, text} ->
            reply =
              jsonrpc_result(id, %{
                "contents" => [%{"uri" => uri, "mimeType" => @transcript_mime, "text" => text}]
              })

            {:reply, reply, state}

          :error ->
            {:reply, jsonrpc_error(id, -32002, "Resource not found: #{uri}"), state}
        end
    end
  end

  defp dispatch("resources/read", _params, id, state) do
    {:reply, jsonrpc_error(id, -32602, "Missing required parameter 'uri'"), state}
  end

  defp dispatch("prompts/list", params, id, state) do
    if is_map(params) and Map.get(params, "cursor") != nil do
      {:reply, jsonrpc_error(id, -32602, "Invalid cursor"), state}
    else
      # Each harness is a prompt, so a host offers it as a command. `plan_architecture` stays as an
      # alias, because hosts that saved it would break without it.
      harness_prompts =
        for harness <- Harness.list() do
          %{
            "name" => harness.id(),
            "title" => harness.name(),
            "description" => harness.description(),
            "arguments" => [
              %{
                "name" => "goal",
                "description" => "What the harness should do",
                "required" => true
              }
            ]
          }
        end

      alias_prompt = %{
        "name" => "plan_architecture",
        "description" =>
          "Creates an architectural implementation plan before executing code changes",
        "arguments" => [
          %{"name" => "goal", "description" => "Engineering task description", "required" => true}
        ]
      }

      {:reply, jsonrpc_result(id, %{"prompts" => harness_prompts ++ [alias_prompt]}), state}
    end
  end

  defp dispatch("prompts/get", %{"name" => "plan_architecture"} = params, id, state) do
    args = Map.get(params, "arguments", %{})
    goal = Map.get(args, "goal", "")

    reply =
      jsonrpc_result(id, %{
        "description" => "Plan architecture for #{goal}",
        "messages" => [
          %{
            "role" => "user",
            "content" => %{
              "type" => "text",
              "text" => "Please create an architectural plan for: #{goal}"
            }
          }
        ]
      })

    {:reply, reply, state}
  end

  defp dispatch("prompts/get", %{"name" => name} = params, id, state) when is_binary(name) do
    args = Map.get(params, "arguments")
    goal = if is_map(args), do: Map.get(args, "goal"), else: nil

    with {:ok, harness} <- fetch_listed_harness(name),
         true <- is_binary(goal) and String.trim(goal) != "" do
      text =
        "Delegate this goal to the Super-Pi `#{harness.id()}` harness with the `harness_task` tool " <>
          "(harness: \"#{harness.id()}\"):\n\n#{goal}"

      reply =
        jsonrpc_result(id, %{
          "description" => "#{harness.name()}: #{harness.description()}",
          "messages" => [%{"role" => "user", "content" => %{"type" => "text", "text" => text}}]
        })

      {:reply, reply, state}
    else
      :error -> {:reply, jsonrpc_error(id, -32602, "Unknown prompt: #{name}"), state}
      false -> {:reply, jsonrpc_error(id, -32602, "Missing required argument 'goal'"), state}
    end
  end

  defp dispatch("prompts/get", %{"name" => unknown}, id, state) do
    {:reply, jsonrpc_error(id, -32602, "Unknown prompt: #{inspect(unknown)}"), state}
  end

  defp dispatch("prompts/get", _params, id, state) do
    {:reply, jsonrpc_error(id, -32602, "Missing required parameter 'name'"), state}
  end

  defp dispatch(unknown_method, _params, id, state) do
    {:reply, jsonrpc_error(id, -32601, "Method not found: #{unknown_method}"), state}
  end

  @doc "Protocol versions this server speaks, newest first."
  def supported_versions, do: @supported_versions

  @doc """
  The version to answer `initialize` with: the client's when supported, else the newest supported.
  The client then decides whether it can speak that version (MCP lifecycle, version negotiation).
  """
  @spec negotiate_version(term()) :: String.t()
  def negotiate_version(requested) when requested in @supported_versions, do: requested
  def negotiate_version(_requested), do: hd(@supported_versions)

  # --- Tool Schema Definitions ---

  # Hosts decide what to run without asking from these hints, so each tool states all four. A hint is
  # a claim for the host's UI, not an enforcement: the permission policy decides what runs.
  # `bash` and `harness_task` can reach anything the process can, hence `openWorldHint`.
  @annotations %{
    "read" => %{
      "readOnlyHint" => true,
      "destructiveHint" => false,
      "idempotentHint" => true,
      "openWorldHint" => false
    },
    "write" => %{
      "readOnlyHint" => false,
      "destructiveHint" => true,
      "idempotentHint" => true,
      "openWorldHint" => false
    },
    "edit" => %{
      "readOnlyHint" => false,
      "destructiveHint" => true,
      "idempotentHint" => false,
      "openWorldHint" => false
    },
    "bash" => %{
      "readOnlyHint" => false,
      "destructiveHint" => true,
      "idempotentHint" => false,
      "openWorldHint" => true
    },
    "grep" => %{
      "readOnlyHint" => true,
      "destructiveHint" => false,
      "idempotentHint" => true,
      "openWorldHint" => false
    },
    "find" => %{
      "readOnlyHint" => true,
      "destructiveHint" => false,
      "idempotentHint" => true,
      "openWorldHint" => false
    },
    "ls" => %{
      "readOnlyHint" => true,
      "destructiveHint" => false,
      "idempotentHint" => true,
      "openWorldHint" => false
    },
    "harness_task" => %{
      "readOnlyHint" => false,
      "destructiveHint" => true,
      "idempotentHint" => false,
      "openWorldHint" => true
    }
  }

  @doc "The eight tools with their input schema and annotations. `harness_task` lists the harness ids."
  def tool_definitions do
    Enum.map(base_tool_definitions(), fn %{"name" => name} = tool ->
      tool
      |> Map.put("annotations", Map.fetch!(@annotations, name))
      |> put_harness_choices()
    end)
  end

  defp put_harness_choices(%{"name" => "harness_task"} = tool) do
    put_in(
      tool,
      ["inputSchema", "properties", "harness", "enum"],
      Enum.map(Harness.list(), & &1.id())
    )
  end

  defp put_harness_choices(tool), do: tool

  defp base_tool_definitions do
    [
      %{
        "name" => "read",
        "description" => "Read file contents with optional line offset and limit",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "path" => %{"type" => "string", "description" => "Relative or absolute file path"},
            "offset" => %{"type" => "integer", "description" => "1-based starting line offset"},
            "limit" => %{"type" => "integer", "description" => "Maximum number of lines to read"}
          },
          "required" => ["path"]
        }
      },
      %{
        "name" => "write",
        "description" => "Write full contents to a file under safe FileLock isolation",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "path" => %{"type" => "string", "description" => "Path to file"},
            "content" => %{"type" => "string", "description" => "Complete text contents to write"}
          },
          "required" => ["path", "content"]
        }
      },
      %{
        "name" => "edit",
        "description" =>
          "Perform exact string replacement in a file under safe FileLock isolation",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "path" => %{"type" => "string", "description" => "Path to file"},
            "old_text" => %{"type" => "string", "description" => "Exact target text to replace"},
            "new_text" => %{"type" => "string", "description" => "Replacement text"}
          },
          "required" => ["path", "old_text", "new_text"]
        }
      },
      %{
        "name" => "bash",
        "description" => "Execute shell command safely with 4 MiB spill protection and timeout",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "command" => %{
              "type" => "string",
              "description" => "Shell command to execute in sandbox"
            }
          },
          "required" => ["command"]
        }
      },
      %{
        "name" => "grep",
        "description" => "Search files by regex pattern",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "pattern" => %{"type" => "string", "description" => "Regex pattern"},
            "path" => %{"type" => "string", "description" => "Directory or file path to search"}
          },
          "required" => ["pattern"]
        }
      },
      %{
        "name" => "find",
        "description" => "List non-ignored files matching a glob or substring pattern",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "pattern" => %{"type" => "string", "description" => "Glob pattern or substring"}
          },
          "required" => ["pattern"]
        }
      },
      %{
        "name" => "ls",
        "description" => "List immediate directory entries",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "path" => %{"type" => "string", "description" => "Directory path"}
          }
        }
      },
      %{
        "name" => "harness_task",
        "description" => "Delegate an autonomous goal to the Super-Pi-BEAM durable state machine",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "prompt" => %{
              "type" => "string",
              "description" => "Task prompt for the durable agent"
            },
            "harness" => %{
              "type" => "string",
              "description" =>
                "Harness that runs the task (see prompts/list). Default: the connection's harness"
            }
          },
          "required" => ["prompt"]
        }
      }
    ]
  end

  defp authorize_tool(name, args, state) do
    {session, state} = tool_session(state)
    ctx = %{conversation_id: session.conversation_id, workspace_root: session.workspace_root}

    case SuperPi.Extension.run_before_tool(session.extensions, name, args, ctx) do
      {:allow, final_args} -> {{:ok, final_args}, state}
      {:allow_overwritten, final_args, _keys} -> {{:ok, final_args}, state}
      {:block, reason} -> {{:blocked, reason}, state}
    end
  end

  # One conversation per MCP connection holds the permission policy for direct tool calls.
  defp tool_session(%{tool_session: session} = state), do: {session, state}

  defp tool_session(state) do
    harness = connection_harness(state)
    agent = SuperPi.Plugins.Permissions.apply_remote_mode(harness.agent_defaults(), nil)
    conv = Storage.create_conversation!(agent: agent, owner: principal(state))

    session = %{
      conversation_id: conv.id,
      workspace_root:
        agent |> Map.get("workspacePaths") |> List.wrap() |> List.first() || workspace_root(),
      extensions: Harness.remote_extensions(harness)
    }

    {session, Map.put(state, :tool_session, session)}
  end

  # The harness of direct tool calls, chosen on purpose: the connection's own (`:harness` in the
  # state), else `config :super_pi, :mcp_harness`, else the application default.
  defp connection_harness(state) do
    case Map.get(state, :harness) || Application.get_env(:super_pi, :mcp_harness) do
      nil ->
        Harness.default()

      name ->
        case Harness.fetch(name) do
          {:ok, harness} -> harness
          {:error, _} -> Harness.default()
        end
    end
  end

  defp principal(state), do: Map.get(state, :principal) || Auth.anonymous()

  # Where tools work. The conversation's own `workspacePaths` come from the same source.
  defp workspace_root, do: hd(Discovery.default_workspace_paths())

  defp fetch_listed_harness(name) do
    case Enum.find(Harness.list(), &(&1.id() == name)) do
      nil -> :error
      harness -> {:ok, harness}
    end
  end

  defp harness_task(args, state) do
    prompt = Map.get(args, "prompt") || Map.get(args, :prompt)
    requested = Map.get(args, "harness") || Map.get(args, :harness)

    with {:prompt, true} <- {:prompt, is_binary(prompt) and byte_size(prompt) > 0},
         {:ok, harness} <- select_harness(requested, state) do
      {result, conv_id} = execute_harness_task(prompt, harness, principal(state))
      {result, remember_conversation(state, conv_id)}
    else
      {:prompt, false} ->
        {%{"output" => "Missing required argument 'prompt'", "is_error" => true}, state}

      {:error, message} ->
        {%{"output" => message, "is_error" => true}, state}
    end
  end

  # No `harness` argument means the connection's harness. A name that is not a harness is an
  # error: `Harness.resolve/1` would run the default one in its place.
  defp select_harness(nil, state), do: {:ok, connection_harness(state)}

  defp select_harness(name, _state) when is_binary(name) do
    case Harness.fetch(name) do
      {:ok, harness} ->
        {:ok, harness}

      {:error, _} ->
        known = Enum.map_join(Harness.list(), ", ", & &1.id())
        {:error, "Unknown harness #{inspect(name)}. Available: #{known}"}
    end
  end

  defp select_harness(_other, _state), do: {:error, "Argument 'harness' must be a string"}

  defp remember_conversation(state, nil), do: state

  defp remember_conversation(state, conv_id),
    do: Map.update(state, :conversations, [conv_id], &Enum.take([conv_id | &1], 50))

  defp execute_harness_task(prompt, harness, principal) do
    extensions = Harness.remote_extensions(harness)
    agent = SuperPi.Plugins.Permissions.apply_remote_mode(harness.agent_defaults(), nil)
    conv = Storage.create_conversation!(agent: agent, owner: principal)
    timeout = Application.get_env(:super_pi, :mcp_harness_task_timeout_ms, 60_000)

    # Supervised, not linked: a crashed machine must not take the MCP stdio server down.
    machine_opts =
      [extensions: extensions] ++ Application.get_env(:super_pi, :mcp_harness_task_opts, [])

    result =
      case SuperPi.Conversation.Locator.ensure_started(conv.id, machine_opts,
             restart: :temporary,
             supervision: :local
           ) do
        {:ok, machine_pid} ->
          run_harness_task(machine_pid, conv.id, prompt, timeout)

        {:error, reason} ->
          %{
            "output" => "Harness task error: could not start: #{inspect(reason)}",
            "is_error" => true
          }
      end

    # The id lets a host read the transcript (`superpi://conversation/{id}/transcript`).
    {Map.put(result, "structured_output", %{
       "harness" => harness.id(),
       "conversation_id" => conv.id
     }), conv.id}
  end

  defp transcript_uri(conv_id), do: "superpi://conversation/#{conv_id}/transcript"

  # A conversation of another principal is reported as not found, so its existence does not leak.
  defp read_transcript("superpi://conversation/" <> rest, state) do
    with [raw_id, "transcript"] <- String.split(rest, "/"),
         {conv_id, ""} <- Integer.parse(raw_id),
         true <- conv_id > 0,
         %SuperPi.Durable.Schemas.Conversation{} <-
           SuperPi.Repo.get(SuperPi.Durable.Schemas.Conversation, conv_id),
         true <- Auth.authorized?(conv_id, principal(state)) do
      {:ok,
       conv_id
       |> TranscriptLogger.transcript_steps()
       |> Enum.map_join("", &(Jason.encode!(&1) <> "\n"))}
    else
      _ -> :error
    end
  end

  defp read_transcript(_uri, _state), do: :error

  defp run_harness_task(machine_pid, conv_id, prompt, timeout) do
    try do
      case SuperPi.Conversation.Machine.submit(machine_pid, prompt,
             mode: :queue,
             timeout: timeout
           ) do
        {:ok, res} ->
          output =
            case res do
              %{"content" => blocks} when is_list(blocks) ->
                Enum.map_join(blocks, "\n", fn
                  %{"text" => t} -> t
                  %{text: t} -> t
                  t when is_binary(t) -> t
                  _ -> ""
                end)

              %{content: blocks} when is_list(blocks) ->
                Enum.map_join(blocks, "\n", fn
                  %{"text" => t} -> t
                  %{text: t} -> t
                  t when is_binary(t) -> t
                  _ -> ""
                end)

              other ->
                inspect(other)
            end

          %{"output" => output, "is_error" => false}

        {:error, reason} ->
          %{"output" => "Harness task error: #{inspect(reason)}", "is_error" => true}
      end
    catch
      :exit, {:timeout, _} ->
        SuperPi.Conversation.Machine.cancel(machine_pid)
        %{"output" => "Harness task timed out after #{timeout} ms", "is_error" => true}

      :exit, reason ->
        %{"output" => "Harness task failed: #{inspect(reason)}", "is_error" => true}
    after
      try do
        :gen_statem.stop(machine_pid)
      catch
        :exit, _ -> :ok
      end

      # The registry drops its entry when it sees the process exit, a moment after `stop`
      # returns. Wait so that no caller can find a dead machine.
      SuperPi.Conversation.Locator.await_gone(conv_id)
    end
  end

  # `structuredContent` is the tool's own structured output, when it has one that JSON can carry.
  defp call_result(result) do
    base = %{
      "content" => [
        %{
          "type" => "text",
          "text" => result |> Map.get("output", "") |> sanitize_utf8() |> to_string()
        }
      ],
      "isError" => Map.get(result, "is_error", false)
    }

    case Map.get(result, "structured_output") do
      %{} = structured when map_size(structured) > 0 ->
        if match?({:ok, _}, Jason.encode(structured)),
          do: Map.put(base, "structuredContent", structured),
          else: base

      _ ->
        base
    end
  end

  defp sanitize_utf8(bin) when is_binary(bin) do
    if String.valid?(bin) do
      bin
    else
      :unicode.characters_to_binary(bin, :latin1, :utf8)
    end
  end

  defp sanitize_utf8(other), do: to_string(other)

  # --- JSON-RPC Helpers ---

  defp jsonrpc_result(id, result) do
    %{"jsonrpc" => "2.0", "id" => id, "result" => result}
  end

  defp jsonrpc_error(id, code, message) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
  end
end
