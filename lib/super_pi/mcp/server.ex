defmodule SuperPi.MCP.Server do
  @moduledoc """
  Model Context Protocol (MCP) Standard Server over `stdio` (`REQ-MCP-01`..`REQ-MCP-04`).

  Allows any MCP-compliant host (OpenCode, Claude Desktop, Cursor, Zed, Continue.dev)
  to connect to Super-Pi-BEAM as a standard tool and context provider.

  ## Supported Methods
  - `initialize` — Handshake declaring tool, resource, and prompt capabilities.
  - `notifications/initialized` — Post-handshake acknowledgment.
  - `ping` — Heartbeat check.
  - `tools/list` — Enumerates all active Super-Pi tools with JSON Schema definitions.
  - `tools/call` — Executes tools within the 4-layer safe sandbox runner.
  - `resources/list` & `resources/read` — Inspects durable conversation documents and transcripts.
  """

  alias SuperPi.Durable.Storage
  alias SuperPi.Tools

  @protocol_version "2024-11-05"
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

    reply =
      jsonrpc_result(id, %{
        "protocolVersion" => @protocol_version,
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

    next_state = Map.put(state, :client_info, client_info)
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
          "content" => [%{"type" => "text", "text" => "Invalid arguments: arguments must be an object"}],
          "isError" => true
        })

      {:reply, reply, state}
    else
      {result, state} =
        case name do
          "harness_task" ->
            result =
              case Map.get(args, "prompt") || Map.get(args, :prompt) do
                prompt when is_binary(prompt) and byte_size(prompt) > 0 ->
                  execute_harness_task(prompt)

                _ ->
                  %{"output" => "Missing required argument 'prompt'", "is_error" => true}
              end

            {result, state}

          other ->
            # Tools run through the default harness's `before_tool` pipeline (permissions,
            # protected paths), the same as a model-issued call.
            case authorize_tool(other, args, state) do
              {{:ok, final_args}, state} ->
                {Tools.execute(other, final_args), state}

              {{:blocked, reason}, state} ->
                {%{"output" => "Blocked: #{reason}", "is_error" => true}, state}
            end
        end

      content_text = sanitize_utf8(Map.get(result, "output", ""))
      is_err = Map.get(result, "is_error", false)

      reply =
        jsonrpc_result(id, %{
          "content" => [
            %{"type" => "text", "text" => to_string(content_text)}
          ],
          "isError" => is_err
        })

      {:reply, reply, state}
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

      {:reply, jsonrpc_result(id, %{"resources" => resources}), state}
    end
  end

  defp dispatch("resources/read", params, id, state) when not is_map(params) do
    {:reply, jsonrpc_error(id, -32602, "Invalid params: resources/read requires an object"), state}
  end

  defp dispatch("resources/read", %{"uri" => uri}, id, state) when is_binary(uri) do
    case uri do
      "superpi://workspace/context" ->
        content =
          Jason.encode!(%{
            "status" => "ready",
            "working_directory" => File.cwd!(),
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
        {:reply, jsonrpc_error(id, -32002, "Resource not found: #{uri}"), state}
    end
  end

  defp dispatch("resources/read", _params, id, state) do
    {:reply, jsonrpc_error(id, -32602, "Missing required parameter 'uri'"), state}
  end

  defp dispatch("prompts/list", params, id, state) do
    if is_map(params) and Map.get(params, "cursor") != nil do
      {:reply, jsonrpc_error(id, -32602, "Invalid cursor"), state}
    else
      prompts = [
        %{
          "name" => "plan_architecture",
          "description" => "Creates an architectural implementation plan before executing code changes",
          "arguments" => [
            %{"name" => "goal", "description" => "Engineering task description", "required" => true}
          ]
        }
      ]

      {:reply, jsonrpc_result(id, %{"prompts" => prompts}), state}
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

  defp dispatch("prompts/get", %{"name" => unknown}, id, state) do
    {:reply, jsonrpc_error(id, -32602, "Unknown prompt: #{unknown}"), state}
  end

  defp dispatch("prompts/get", _params, id, state) do
    {:reply, jsonrpc_error(id, -32602, "Missing required parameter 'name'"), state}
  end

  defp dispatch(unknown_method, _params, id, state) do
    {:reply, jsonrpc_error(id, -32601, "Method not found: #{unknown_method}"), state}
  end

  # --- Tool Schema Definitions ---

  def tool_definitions do
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
        "description" => "Perform exact string replacement in a file under safe FileLock isolation",
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
            "command" => %{"type" => "string", "description" => "Shell command to execute in sandbox"}
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
            "prompt" => %{"type" => "string", "description" => "Task prompt for the durable agent"}
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
    harness = SuperPi.Harness.default()
    agent = SuperPi.Plugins.Permissions.apply_remote_mode(harness.agent_defaults(), nil)
    conv = Storage.create_conversation!(agent: agent)

    session = %{
      conversation_id: conv.id,
      workspace_root: File.cwd!(),
      extensions: SuperPi.Harness.remote_extensions(harness)
    }

    {session, Map.put(state, :tool_session, session)}
  end

  defp execute_harness_task(prompt) do
    harness = SuperPi.Harness.default()
    extensions = SuperPi.Harness.remote_extensions(harness)
    agent = SuperPi.Plugins.Permissions.apply_remote_mode(harness.agent_defaults(), nil)
    conv = Storage.create_conversation!(agent: agent)
    timeout = Application.get_env(:super_pi, :mcp_harness_task_timeout_ms, 60_000)

    # Supervised, not linked: a crashed machine must not take the MCP stdio server down.
    machine_opts = [extensions: extensions] ++ Application.get_env(:super_pi, :mcp_harness_task_opts, [])

    case SuperPi.Conversation.Locator.ensure_started(conv.id, machine_opts, restart: :temporary, supervision: :local) do
      {:ok, machine_pid} -> run_harness_task(machine_pid, conv.id, prompt, timeout)
      {:error, reason} -> %{"output" => "Harness task error: could not start: #{inspect(reason)}", "is_error" => true}
    end
  end

  defp run_harness_task(machine_pid, conv_id, prompt, timeout) do
    try do
      case SuperPi.Conversation.Machine.submit(machine_pid, prompt, mode: :queue, timeout: timeout) do
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
