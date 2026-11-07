defmodule SuperPi.ACPTest do
  use SuperPi.DataCase, async: false

  alias SuperPi.ACP.Server
  alias SuperPi.Durable.Storage
  alias SuperPi.Event
  alias SuperPi.Event.Renderer
  alias SuperPi.TestSupport.Faults

  # --- Renderer ---

  defp render(events), do: Renderer.render_all(Renderer.ACP, events, session_id: "acp_x")

  describe "renderer" do
    test "text and thought deltas are message chunks" do
      assert [
               {:update,
                %{
                  "sessionUpdate" => "agent_message_chunk",
                  "content" => %{"type" => "text", "text" => "hi"}
                }},
               {:update,
                %{"sessionUpdate" => "agent_thought_chunk", "content" => %{"text" => "hm"}}}
             ] = render([Event.text_delta(1, 1, 0, "hi"), Event.thinking_delta(1, 1, 0, "hm")])
    end

    test "a tool call goes pending, then completed, with its kind and a location" do
      [{:update, call}, {:update, done}] =
        render([
          Event.tool_started(1, 1, "c1", "read", %{"path" => "/w/a.ex"}),
          Event.tool_completed(1, 1, "c1", "read", false, "contents")
        ])

      assert %{
               "sessionUpdate" => "tool_call",
               "toolCallId" => "c1",
               "status" => "pending",
               "kind" => "read",
               "locations" => [%{"path" => "/w/a.ex"}]
             } = call

      assert %{
               "sessionUpdate" => "tool_call_update",
               "status" => "completed",
               "rawOutput" => "contents"
             } = done
    end

    test "kinds: commands are execute, edits are edit, unknown tools are other" do
      assert Renderer.ACP.kind("bash") == "execute"
      assert Renderer.ACP.kind("edit") == "edit"
      assert Renderer.ACP.kind("web_fetch") == "fetch"
      assert Renderer.ACP.kind("mcp__a__b") == "other"
    end

    test "a permission request is a request for the pending tool call, with ACP option kinds, and approval moves it to in_progress" do
      req =
        Event.permission_request(1, 1, %{
          "request_id" => "ui-1",
          "tool_call_id" => "c1",
          "tool_name" => "bash",
          "arguments" => %{"command" => "make"},
          "reason" => "r",
          "risk" => "high",
          "options" => Event.permission_options()
        })

      out =
        render([
          Event.tool_started(1, 1, "c1", "bash", %{"command" => "make"}),
          req,
          Event.ui_resolved(1, "ui-1", "answered")
        ])

      assert [
               {:update, %{"sessionUpdate" => "tool_call"}},
               {:permission, params, "ui-1"},
               {:update, %{"status" => "in_progress", "toolCallId" => "c1"}}
             ] = out

      assert %{
               "sessionId" => "acp_x",
               "toolCall" => %{"toolCallId" => "c1", "status" => "pending", "kind" => "execute"}
             } = params

      assert Enum.map(params["options"], & &1["kind"]) == [
               "allow_once",
               "allow_always",
               "reject_once",
               "reject_always"
             ]

      assert Enum.map(params["options"], & &1["optionId"]) == [
               "allow_once",
               "allow_always",
               "reject_once",
               "reject_always"
             ]
    end

    test "a refused request does not claim the tool started" do
      out =
        render([
          Event.tool_started(1, 1, "c1", "bash", %{}),
          Event.permission_request(1, 1, %{
            "request_id" => "u",
            "tool_call_id" => "c1",
            "tool_name" => "bash",
            "options" => []
          }),
          Event.ui_resolved(1, "u", "timeout")
        ])

      refute Enum.any?(out, &match?({:update, %{"status" => "in_progress"}}, &1))
    end

    test "plan and mode updates" do
      assert [
               {:update,
                %{
                  "sessionUpdate" => "plan",
                  "entries" => [
                    %{"content" => "a", "status" => "completed", "priority" => "medium"}
                  ]
                }}
             ] =
               render([Event.plan_updated(1, [%{"id" => 1, "text" => "a", "completed" => true}])])

      assert [{:update, %{"sessionUpdate" => "current_mode_update", "currentModeId" => "plan"}}] =
               render([Event.mode_changed(1, "plan", "plan")])
    end

    test "a subagent shows as a tool call that runs and then completes or fails" do
      out =
        render([
          Event.subagent_started(1, 1, 7, "scout", "find x"),
          Event.subagent_finished(1, 1, 7, "completed", "found it")
        ])

      assert [
               {:update,
                %{
                  "sessionUpdate" => "tool_call",
                  "toolCallId" => "subagent-7",
                  "status" => "in_progress",
                  "title" => "subagent (scout)"
                }},
               {:update,
                %{
                  "sessionUpdate" => "tool_call_update",
                  "toolCallId" => "subagent-7",
                  "status" => "completed",
                  "content" => [%{"content" => %{"text" => "found it"}}]
                }}
             ] = out

      assert [{:update, %{"status" => "failed"}}] =
               render([Event.subagent_finished(1, 1, 7, "failed", "boom")])
    end

    test "turn events render nothing: the server answers the prompt" do
      assert [] =
               render([
                 Event.turn_started(1, 1, 0),
                 Event.turn_completed(1, 1, %{}, 0),
                 Event.state_changed(1, 1, "idle")
               ])
    end
  end

  # --- Server over a fake client ---

  setup do
    test_pid = self()

    {:ok, server} =
      Server.start_link(send: fn line -> send(test_pid, {:acp_out, Jason.decode!(line)}) end)

    # DataCase then waits for the prompt tasks and machines to be idle.
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)

    {:ok, server: server}
  end

  defp rpc(server, id, method, params),
    do:
      send(
        server,
        {:acp_line,
         Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})}
      )

  defp notify(server, method, params),
    do:
      send(
        server,
        {:acp_line, Jason.encode!(%{"jsonrpc" => "2.0", "method" => method, "params" => params})}
      )

  defp respond(server, id, result),
    do:
      send(
        server,
        {:acp_line, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})}
      )

  defp await_response(id), do: await_response(id, [])

  defp await_response(id, seen) do
    receive do
      {:acp_out, %{"id" => ^id} = msg} -> {msg, Enum.reverse(seen)}
      {:acp_out, other} -> await_response(id, [other | seen])
    after
      5_000 -> flunk("no response to #{id}, saw #{inspect(seen)}")
    end
  end

  defp new_session(server, params \\ %{}) do
    rpc(server, 1, "initialize", %{"protocolVersion" => 1, "clientCapabilities" => %{}})
    assert {%{"result" => _}, _} = await_response(1)
    rpc(server, 2, "session/new", Map.merge(%{"cwd" => File.cwd!(), "mcpServers" => []}, params))
    {%{"result" => %{"sessionId" => sid}} = resp, notes} = await_response(2)
    {sid, resp, notes}
  end

  # Replaces the extensions and responder of the session's conversation, which `session/prompt` starts with the harness extensions.
  defp conv_of(sid), do: SuperPi.Gateway.Sessions.lookup(SuperPi.Auth.anonymous(), sid)

  describe "initialize" do
    test "answers the protocol version, capabilities and the harnesses", %{server: server} do
      rpc(server, 1, "initialize", %{
        "protocolVersion" => 1,
        "clientCapabilities" => %{"fs" => %{"readTextFile" => true}}
      })

      {%{"result" => result}, _} = await_response(1)

      assert result["protocolVersion"] == 1
      assert result["agentCapabilities"]["loadSession"] == true
      assert result["agentCapabilities"]["sessionCapabilities"]["additionalDirectories"] == %{}
      assert result["authMethods"] == []

      assert Enum.map(result["_meta"]["superPi"]["harnesses"], & &1["id"]) |> Enum.sort() == [
               "super-pi-assistant",
               "super-pi-code",
               "super-pi-librarian",
               "super-pi-planner"
             ]
    end

    test "a newer client version is answered with ours", %{server: server} do
      rpc(server, 1, "initialize", %{"protocolVersion" => 99})
      assert {%{"result" => %{"protocolVersion" => 1}}, _} = await_response(1)
    end

    test "an unknown method is -32601, an unknown notification is ignored", %{server: server} do
      rpc(server, 7, "nope", %{})
      assert {%{"error" => %{"code" => -32601}}, _} = await_response(7)
      notify(server, "nope", %{})
      refute_receive {:acp_out, _}, 100
    end

    test "garbage is a parse error", %{server: server} do
      send(server, {:acp_line, "{not json"})
      assert_receive {:acp_out, %{"error" => %{"code" => -32700}}}
    end
  end

  describe "authentication" do
    setup do
      Application.put_env(:super_pi, :gateway_tokens, alice: "secret")
      on_exit(fn -> Application.delete_env(:super_pi, :gateway_tokens) end)
      :ok
    end

    test "sessions need a token when the gateway needs one", %{server: server} do
      rpc(server, 1, "initialize", %{"protocolVersion" => 1})
      assert {%{"result" => %{"authMethods" => [%{"id" => "token"}]}}, _} = await_response(1)

      rpc(server, 2, "session/new", %{"cwd" => File.cwd!()})
      assert {%{"error" => %{"code" => -32000}}, _} = await_response(2)

      rpc(server, 3, "authenticate", %{"methodId" => "token", "_meta" => %{"token" => "wrong"}})
      assert {%{"error" => %{"code" => -32000}}, _} = await_response(3)

      rpc(server, 4, "authenticate", %{"methodId" => "token", "_meta" => %{"token" => "secret"}})
      assert {%{"result" => %{}}, _} = await_response(4)

      rpc(server, 5, "session/new", %{"cwd" => File.cwd!()})
      assert {%{"result" => %{"sessionId" => "acp_" <> _}}, _} = await_response(5)
    end
  end

  describe "session/new" do
    test "Zed additional directories are trusted and loads replace editor roots", %{
      server: server
    } do
      primary = File.cwd!()
      secondary = Path.join(System.tmp_dir!(), "acp-secondary")
      approved = Path.join(System.tmp_dir!(), "acp-approved")

      {sid, _, _} =
        new_session(server, %{"additionalDirectories" => [secondary, primary, secondary]})

      id = conv_of(sid)

      assert SuperPi.Durable.Doc.snapshot("conversation", id, "pi.agent")["workspacePaths"] ==
               [primary, secondary]

      Storage.configure_agent!(id, %{"approvedWorkspacePaths" => [approved]})

      rpc(server, 3, "session/load", %{
        "sessionId" => sid,
        "cwd" => secondary,
        "additionalDirectories" => [primary]
      })

      assert {%{"result" => _}, _} = await_response(3)
      agent = SuperPi.Durable.Doc.snapshot("conversation", id, "pi.agent")
      assert agent["workspacePaths"] == [secondary, primary, approved]
      assert {:ok, %{root: ^secondary}} = SuperPi.Env.Workspace.resolve(%{conversation_id: id})

      rpc(server, 4, "session/load", %{"sessionId" => sid, "cwd" => primary})
      assert {%{"result" => _}, _} = await_response(4)

      assert SuperPi.Durable.Doc.snapshot("conversation", id, "pi.agent")["workspacePaths"] == [
               primary,
               approved
             ]

      Storage.append_entry!(id, "pi.message", %{
        "role" => "user",
        "content" => [%{"type" => "text", "text" => "q"}]
      })

      rpc(server, 5, "_superpi/session/fork", %{"sessionId" => sid})
      assert {%{"result" => %{"sessionId" => fork}}, _} = await_response(5)
      forked = SuperPi.Durable.Doc.snapshot("conversation", conv_of(fork), "pi.agent")
      assert forked["workspacePaths"] == [primary, approved]
      assert forked["approvedWorkspacePaths"] == [approved]
    end

    test "malformed additional directories are rejected on create and load", %{server: server} do
      {sid, _, _} = new_session(server)

      for directories <- [
            false,
            "not-an-array",
            ["relative/path"],
            [nil],
            [42],
            [%{"path" => "/tmp"}],
            ["/tmp/" <> <<0>>]
          ],
          method <- ["session/new", "session/load"] do
        rpc(server, 3, method, %{
          "sessionId" => sid,
          "cwd" => File.cwd!(),
          "additionalDirectories" => directories
        })

        assert {%{"error" => %{"code" => -32602}}, _} = await_response(3)
      end

      assert SuperPi.Durable.Doc.snapshot("conversation", conv_of(sid), "pi.agent")[
               "workspacePaths"
             ] == [File.cwd!()]
    end

    test "creates a conversation with the cwd as workspace, an opaque id, modes and commands", %{
      server: server
    } do
      {sid, resp, notes} = new_session(server)
      assert "acp_" <> _ = sid
      refute sid =~ ~r/^\d+$/

      conv_id = conv_of(sid)
      agent = SuperPi.Durable.Doc.snapshot("conversation", conv_id, "pi.agent")
      assert agent["workspacePaths"] == [File.cwd!()]
      assert agent["harness"] == "super-pi-code"

      assert %{"currentModeId" => "ask", "availableModes" => modes} =
               resp["result"]["modes"]

      assert Enum.map(modes, & &1["id"]) == ["ask", "plan", "build"]
      assert agent["profile"] == "ask"
      assert agent["executionMode"] == "plan"

      assert [%{"currentValue" => "ask", "category" => "mode", "type" => "select"}] =
               resp["result"]["configOptions"]

      cmds =
        Enum.find(
          notes ++ drain(),
          &(get_in(&1, ["params", "update", "sessionUpdate"]) == "available_commands_update")
        )

      assert cmds ||
               assert_receive(
                 {:acp_out,
                  %{
                    "params" => %{
                      "update" => %{
                        "sessionUpdate" => "available_commands_update",
                        "availableCommands" => [%{"name" => "plan"} | _]
                      }
                    }
                  }}
               )
    end

    test "the harness can be chosen, a bad one and a relative cwd are rejected", %{server: server} do
      {sid, _, _} = new_session(server, %{"_meta" => %{"harness" => "super-pi-planner"}})

      assert SuperPi.Durable.Doc.snapshot("conversation", conv_of(sid), "pi.agent")[
               "executionMode"
             ] == "plan"

      rpc(server, 3, "session/new", %{"cwd" => File.cwd!(), "_meta" => %{"harness" => "nope"}})
      assert {%{"error" => %{"code" => -32602}}, _} = await_response(3)

      rpc(server, 4, "session/new", %{"cwd" => "relative/path"})
      assert {%{"error" => %{"code" => -32602}}, _} = await_response(4)
    end

    test "set_mode accepts an available mode only", %{server: server} do
      {sid, _, _} = new_session(server)
      rpc(server, 3, "session/set_mode", %{"sessionId" => sid, "modeId" => "plan"})
      assert {%{"result" => %{}}, _} = await_response(3)

      assert SuperPi.Durable.Doc.snapshot("conversation", conv_of(sid), "pi.agent")[
               "executionMode"
             ] == "plan"

      assert_receive {:acp_out,
                      %{
                        "params" => %{
                          "update" => %{
                            "sessionUpdate" => "current_mode_update",
                            "currentModeId" => "plan"
                          }
                        }
                      }}

      rpc(server, 4, "session/set_mode", %{"sessionId" => sid, "modeId" => "auto"})
      assert {%{"error" => %{"code" => -32602}}, _} = await_response(4)
    end

    test "Ask and Plan emit distinct mode updates and survive session reload", %{server: server} do
      {sid, _, _} = new_session(server)

      for {mode, id} <- [{"plan", 3}, {"ask", 4}, {"build", 5}, {"ask", 6}] do
        rpc(server, id, "session/set_mode", %{"sessionId" => sid, "modeId" => mode})
        assert {%{"result" => %{}}, notes} = await_response(id)

        unless Enum.any?(notes, &(get_in(&1, ["params", "update", "currentModeId"]) == mode)) do
          assert_receive {:acp_out,
                          %{
                            "params" => %{
                              "update" => %{
                                "sessionUpdate" => "current_mode_update",
                                "currentModeId" => ^mode
                              }
                            }
                          }}
        end

        agent = SuperPi.Durable.Doc.snapshot("conversation", conv_of(sid), "pi.agent")
        assert agent["profile"] == mode
        assert agent["executionMode"] == if(mode == "build", do: "accept-edits", else: "plan")
      end

      rpc(server, 7, "session/load", %{"sessionId" => sid, "cwd" => File.cwd!()})
      assert {%{"result" => %{"modes" => %{"currentModeId" => "ask"}}}, _} = await_response(7)
    end

    test "config options and legacy modes share a selector and synchronized notifications", %{
      server: server
    } do
      {sid, _, _} = new_session(server)

      rpc(server, 3, "session/set_config_option", %{
        "sessionId" => sid,
        "configId" => "mode",
        "type" => "id",
        "value" => "build"
      })

      assert {%{"result" => %{"configOptions" => [%{"currentValue" => "build"}]}}, notes} =
               await_response(3)

      updates = notes ++ drain()

      for kind <- ["current_mode_update", "config_option_update"] do
        unless Enum.any?(updates, &(get_in(&1, ["params", "update", "sessionUpdate"]) == kind)) do
          assert_receive {:acp_out, %{"params" => %{"update" => %{"sessionUpdate" => ^kind}}}}
        end
      end

      assert SuperPi.ACP.Session.modes(conv_of(sid))["currentModeId"] == "build"

      rpc(server, 4, "session/set_config_option", %{
        "sessionId" => sid,
        "configId" => "mode",
        "value" => "plan"
      })

      assert {%{"result" => %{"configOptions" => [%{"currentValue" => "plan"}]}}, _} =
               await_response(4)

      rpc(server, 5, "session/set_config_option", %{
        "sessionId" => sid,
        "configId" => "invalid",
        "value" => "build"
      })

      assert {%{"error" => _}, _} = await_response(5)
      assert SuperPi.ACP.Session.modes(conv_of(sid))["currentModeId"] == "plan"
    end

    test "loading a legacy auto session adopts Build with command approvals", %{server: server} do
      {sid, _, _} = new_session(server)

      Storage.configure_agent!(conv_of(sid), %{
        "workflowMode" => nil,
        "profile" => nil,
        "profilePolicy" => nil,
        "profilesConfig" => nil,
        "executionMode" => "auto"
      })

      rpc(server, 3, "session/load", %{"sessionId" => sid, "cwd" => File.cwd!()})
      assert {%{"result" => %{"modes" => %{"currentModeId" => "build"}}}, _} = await_response(3)

      assert SuperPi.Durable.Doc.snapshot("conversation", conv_of(sid), "pi.agent")[
               "executionMode"
             ] == "accept-edits"
    end

    test "a read-only remote ceiling hides Build and prevents slash-command elevation", %{
      server: server
    } do
      saved = Application.fetch_env(:super_pi, :permissions)
      Application.put_env(:super_pi, :permissions, remote_max_mode: "plan")

      on_exit(fn ->
        case saved do
          {:ok, value} -> Application.put_env(:super_pi, :permissions, value)
          :error -> Application.delete_env(:super_pi, :permissions)
        end
      end)

      {sid, resp, _} = new_session(server)
      assert Enum.map(resp["result"]["modes"]["availableModes"], & &1["id"]) == ["ask", "plan"]
      rpc(server, 3, "session/set_mode", %{"sessionId" => sid, "modeId" => "build"})
      assert {%{"error" => %{"code" => -32602}}, _} = await_response(3)

      assert {:error, _} =
               SuperPi.Plugins.SlashCommands.on_input("/workflow build", %{
                 conversation_id: conv_of(sid)
               })
    end
  end

  defp drain do
    receive do
      {:acp_out, m} -> [m | drain()]
    after
      0 -> []
    end
  end

  # A machine for the session's conversation with a scripted model, so `session/prompt` uses it.
  defp scripted(sid, responder, extra \\ []) do
    conv_id = conv_of(sid)

    {:ok, _pid} =
      SuperPi.Conversation.Locator.ensure_started(conv_id, [llm_responder: responder] ++ extra)

    conv_id
  end

  describe "mcpServers" do
    setup do
      Application.put_env(:super_pi, :mcp_clients, true)
      on_exit(fn -> Application.put_env(:super_pi, :mcp_clients, false) end)
      SuperPi.MCP.Manager.stop_all()
      on_exit(&SuperPi.MCP.Manager.stop_all/0)
      {:ok, fake} = SuperPi.TestSupport.FakeHTTPMCP.start()
      on_exit(fn -> SuperPi.TestSupport.FakeHTTPMCP.stop(fake) end)
      {:ok, fake: fake}
    end

    test "the servers belong to the session's conversation and stop with the connection", %{
      server: server,
      fake: fake
    } do
      {sid, _resp, _notes} =
        new_session(server, %{
          "mcpServers" => [%{"type" => "http", "name" => "hosted", "url" => fake.url}]
        })

      conv_id = conv_of(sid)
      tools = SuperPi.Durable.Doc.snapshot("conversation", conv_id, "pi.agent")["tools"]
      assert Enum.any?(tools, &(&1["name"] == "mcp__hosted__echo"))
      assert "mcp__hosted__echo" in SuperPi.MCP.Manager.tool_names(conv_id)
      assert SuperPi.MCP.Manager.tool_names() == []

      GenServer.stop(server)
      assert SuperPi.MCP.Manager.tool_names(conv_id) == []
    end
  end

  describe "session/prompt" do
    test "ACP notifications escape Unicode on stdout" do
      test_pid = self()

      {:ok, server} =
        Server.start_link(
          send: fn line ->
            if String.contains?(line, "agent_message_chunk"),
              do: send(test_pid, {:raw_acp_chunk, line})

            send(test_pid, {:acp_out, Jason.decode!(line)})
          end
        )

      on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
      {sid, _, _} = new_session(server)

      scripted(sid, fn _payload, ctx ->
        ctx.emit_event.(%{"type" => "text_delta", "index" => 0, "delta" => "I’m “ready”"})
        {:ok, Faults.text_msg("I’m “ready”")}
      end)

      rpc(server, 10, "session/prompt", %{
        "sessionId" => sid,
        "prompt" => [%{"type" => "text", "text" => "hi"}]
      })

      assert {%{"result" => %{"stopReason" => "end_turn"}}, _} = await_response(10)
      assert_receive {:raw_acp_chunk, line}
      assert Enum.all?(:binary.bin_to_list(line), &(&1 < 128))
      assert get_in(Jason.decode!(line), ["params", "update", "content", "text"]) == "I’m “ready”"
    end

    test "streams message chunks and answers end_turn", %{server: server} do
      {sid, _, _} = new_session(server)

      scripted(sid, fn _p, ctx ->
        ctx.emit_event.(%{"type" => "text_delta", "index" => 0, "delta" => "Hel"})
        ctx.emit_event.(%{"type" => "text_delta", "index" => 0, "delta" => "lo"})
        {:ok, Faults.text_msg("Hello")}
      end)

      rpc(server, 10, "session/prompt", %{
        "sessionId" => sid,
        "prompt" => [%{"type" => "text", "text" => "hi"}]
      })

      {resp, notes} = await_response(10)

      assert %{"result" => %{"stopReason" => "end_turn"}} = resp

      chunks =
        for %{
              "params" => %{
                "update" => %{
                  "sessionUpdate" => "agent_message_chunk",
                  "content" => %{"text" => t}
                }
              }
            } <- notes,
            do: t

      assert Enum.join(chunks) == "Hello"
    end

    test "a failing model gives an error message and the refusal stop reason", %{server: server} do
      {sid, _, _} = new_session(server)
      scripted(sid, fn _p, _c -> {:error, "provider down"} end)

      rpc(server, 10, "session/prompt", %{
        "sessionId" => sid,
        "prompt" => [%{"type" => "text", "text" => "hi"}]
      })

      {resp, notes} = await_response(10)
      assert %{"result" => %{"stopReason" => "refusal"}} = resp

      assert Enum.any?(
               notes,
               &String.contains?(
                 to_string(get_in(&1, ["params", "update", "content", "text"])),
                 "provider down"
               )
             )
    end

    test "a cancel arrives during the prompt and ends it with cancelled", %{server: server} do
      {sid, _, _} = new_session(server)
      scripted(sid, Faults.blocking_responder(self(), "x"))

      rpc(server, 10, "session/prompt", %{
        "sessionId" => sid,
        "prompt" => [%{"type" => "text", "text" => "long"}]
      })

      assert_receive {:responder_started, responder}, 5_000
      on_exit(fn -> if Process.alive?(responder), do: send(responder, :release) end)

      notify(server, "session/cancel", %{"sessionId" => sid})
      assert {%{"result" => %{"stopReason" => "cancelled"}}, _} = await_response(10)
    end

    test "a second prompt while one runs is refused, an empty one too", %{server: server} do
      {sid, _, _} = new_session(server)
      scripted(sid, Faults.blocking_responder(self(), "x"))

      rpc(server, 10, "session/prompt", %{
        "sessionId" => sid,
        "prompt" => [%{"type" => "text", "text" => "a"}]
      })

      assert_receive {:responder_started, responder}, 5_000
      on_exit(fn -> if Process.alive?(responder), do: send(responder, :release) end)

      rpc(server, 11, "session/prompt", %{
        "sessionId" => sid,
        "prompt" => [%{"type" => "text", "text" => "b"}]
      })

      assert {%{"error" => %{"code" => -32602}}, _} = await_response(11)

      rpc(server, 12, "session/prompt", %{"sessionId" => "acp_nope", "prompt" => []})
      assert {%{"error" => %{"code" => -32602}}, _} = await_response(12)
      send(responder, :release)
    end

    test "mode changes wait for an active prompt to finish", %{server: server} do
      {sid, _, _} = new_session(server)
      scripted(sid, Faults.blocking_responder(self(), "done"))

      rpc(server, 10, "session/prompt", %{
        "sessionId" => sid,
        "prompt" => [%{"type" => "text", "text" => "go"}]
      })

      assert_receive {:responder_started, pid}, 5_000
      rpc(server, 11, "session/set_mode", %{"sessionId" => sid, "modeId" => "ask"})
      assert {%{"error" => %{"code" => -32602}}, _} = await_response(11)
      send(pid, :release)
      assert {%{"result" => %{"stopReason" => "end_turn"}}, _} = await_response(10)
    end

    test "a tool that needs approval sends session/request_permission, and the answer decides", %{
      server: server
    } do
      {sid, _, _} = new_session(server, %{"_meta" => %{"harness" => "super-pi-code"}})
      conv_id = conv_of(sid)
      :ok = SuperPi.ACP.Session.set_mode(conv_id, "build")

      SuperPi.Durable.Storage.configure_agent!(conv_id, %{
        "tools" => [%{"name" => "mcp__x__y", "effects" => ["net_write"]}]
      })

      test_pid = self()

      scripted(sid, Faults.tool_then_text_responder("mcp__x__y", %{}, "done"),
        tool_executor: fn name, _a, _c ->
          send(test_pid, {:executed, name})
          %{"output" => "ok"}
        end,
        extensions: SuperPi.Harness.remote_extensions(SuperPi.Harness.Code)
      )

      rpc(server, 10, "session/prompt", %{
        "sessionId" => sid,
        "prompt" => [%{"type" => "text", "text" => "go"}]
      })

      assert_receive {:acp_out,
                      %{
                        "method" => "session/request_permission",
                        "id" => req_id,
                        "params" => params
                      }},
                     5_000

      assert params["toolCall"]["toolCallId"] == "call_1"
      assert params["toolCall"]["status"] == "pending"
      refute_received {:executed, _}

      respond(server, req_id, %{
        "outcome" => %{"outcome" => "selected", "optionId" => "allow_once"}
      })

      assert {%{"result" => %{"stopReason" => "end_turn"}}, notes} = await_response(10)
      assert_received {:executed, "mcp__x__y"}
      assert Enum.any?(notes, &(get_in(&1, ["params", "update", "status"]) == "completed"))
    end

    test "rejecting a permission blocks the tool", %{server: server} do
      {sid, _, _} = new_session(server)
      :ok = SuperPi.ACP.Session.set_mode(conv_of(sid), "build")

      SuperPi.Durable.Storage.configure_agent!(conv_of(sid), %{
        "tools" => [%{"name" => "mcp__x__y", "effects" => ["net_write"]}]
      })

      test_pid = self()

      scripted(sid, Faults.tool_then_text_responder("mcp__x__y", %{}, "done"),
        tool_executor: fn name, _a, _c ->
          send(test_pid, {:executed, name})
          %{"output" => "ok"}
        end,
        extensions: SuperPi.Harness.remote_extensions(SuperPi.Harness.Code)
      )

      rpc(server, 10, "session/prompt", %{
        "sessionId" => sid,
        "prompt" => [%{"type" => "text", "text" => "go"}]
      })

      assert_receive {:acp_out, %{"method" => "session/request_permission", "id" => req_id}},
                     5_000

      respond(server, req_id, %{
        "outcome" => %{"outcome" => "selected", "optionId" => "reject_once"}
      })

      assert {%{"result" => %{"stopReason" => "end_turn"}}, _} = await_response(10)
      refute_received {:executed, _}
    end
  end

  describe "session/load and fork" do
    test "load replays the history and resumes the same conversation; an unknown id is -32002", %{
      server: server
    } do
      {sid, _, _} = new_session(server)
      conv_id = conv_of(sid)

      Storage.append_entry!(conv_id, "pi.message", %{
        "role" => "user",
        "content" => [%{"type" => "text", "text" => "question"}]
      })

      Storage.append_entry!(conv_id, "pi.message", %{
        "role" => "assistant",
        "content" => [%{"type" => "text", "text" => "answer"}]
      })

      # A second client process, as after an editor restart.
      test_pid = self()

      {:ok, server2} =
        Server.start_link(send: fn line -> send(test_pid, {:acp_out, Jason.decode!(line)}) end)

      on_exit(fn -> if Process.alive?(server2), do: GenServer.stop(server2) end)
      rpc(server2, 1, "initialize", %{"protocolVersion" => 1})
      await_response(1)

      rpc(server2, 2, "session/load", %{
        "sessionId" => sid,
        "cwd" => File.cwd!(),
        "mcpServers" => []
      })

      {resp, notes} = await_response(2)

      assert %{"result" => %{"modes" => _}} = resp
      kinds = for %{"params" => %{"update" => %{"sessionUpdate" => k}}} <- notes, do: k
      assert Enum.take(kinds, 2) == ["user_message_chunk", "agent_message_chunk"]
      assert conv_of(sid) == conv_id

      rpc(server2, 3, "session/load", %{"sessionId" => "acp_missing", "cwd" => File.cwd!()})
      assert {%{"error" => %{"code" => -32002}}, _} = await_response(3)
    end

    test "_superpi/session/fork makes a new session on a fork of the conversation", %{
      server: server
    } do
      {sid, _, _} = new_session(server)

      Storage.append_entry!(conv_of(sid), "pi.message", %{
        "role" => "user",
        "content" => [%{"type" => "text", "text" => "q"}]
      })

      rpc(server, 3, "_superpi/session/fork", %{"sessionId" => sid})
      assert {%{"result" => %{"sessionId" => new_sid}}, _} = await_response(3)
      assert new_sid != sid
      assert conv_of(new_sid) != conv_of(sid)
      assert [%{"text" => "q"}] = SuperPi.Event.History.messages(conv_of(new_sid))
    end
  end

  describe "client file system" do
    alias SuperPi.Env.ClientFS

    test "an editor buffer in an additional directory is delegated", %{server: server} do
      rpc(server, 1, "initialize", %{
        "protocolVersion" => 1,
        "clientCapabilities" => %{"fs" => %{"readTextFile" => true}}
      })

      await_response(1)
      secondary = Path.join(System.tmp_dir!(), "acp-buffer-secondary")

      rpc(server, 2, "session/new", %{
        "cwd" => File.cwd!(),
        "additionalDirectories" => [secondary]
      })

      {%{"result" => %{"sessionId" => sid}}, _} = await_response(2)
      path = Path.join(secondary, "unsaved.ex")

      task =
        Task.async(fn ->
          SuperPi.Tools.execute("read", %{"path" => path}, %{conversation_id: conv_of(sid)})
        end)

      assert_receive {:acp_out,
                      %{
                        "method" => "fs/read_text_file",
                        "id" => id,
                        "params" => %{"path" => ^path}
                      }},
                     2000

      respond(server, id, %{"content" => "secondary unsaved buffer"})
      assert Task.await(task)["output"] == "secondary unsaved buffer"
    end

    test "an unsaved buffer is served by the client, a failure falls back, :never skips", %{
      server: server
    } do
      rpc(server, 1, "initialize", %{
        "protocolVersion" => 1,
        "clientCapabilities" => %{"fs" => %{"readTextFile" => true}}
      })

      await_response(1)
      rpc(server, 2, "session/new", %{"cwd" => File.cwd!()})
      {%{"result" => %{"sessionId" => sid}}, _} = await_response(2)
      conv_id = conv_of(sid)
      path = Path.join(File.cwd!(), "mix.exs")
      ws = %SuperPi.Env.Workspace{kind: "local"}

      task =
        Task.async(fn ->
          ClientFS.maybe_read(%{conversation_id: conv_id}, ws, path, line: 1, limit: 5)
        end)

      assert_receive {:acp_out,
                      %{
                        "method" => "fs/read_text_file",
                        "id" => id,
                        "params" => %{
                          "sessionId" => ^sid,
                          "path" => ^path,
                          "line" => 1,
                          "limit" => 5
                        }
                      }},
                     2_000

      respond(server, id, %{"content" => "unsaved buffer"})
      assert {:ok, "unsaved buffer"} = Task.await(task)

      task = Task.async(fn -> ClientFS.maybe_read(%{conversation_id: conv_id}, ws, path, []) end)
      assert_receive {:acp_out, %{"method" => "fs/read_text_file", "id" => id}}, 2_000

      send(
        server,
        {:acp_line,
         Jason.encode!(%{
           "jsonrpc" => "2.0",
           "id" => id,
           "error" => %{"code" => -32002, "message" => "no such file"}
         })}
      )

      assert :skip = Task.await(task)

      # A path outside the workspace never leaves the process.
      assert :skip = ClientFS.maybe_read(%{conversation_id: conv_id}, ws, "/etc/passwd", [])
      refute_receive {:acp_out, %{"method" => "fs/read_text_file"}}, 100

      Application.put_env(:super_pi, :acp, fs_delegation: :never)
      on_exit(fn -> Application.delete_env(:super_pi, :acp) end)
      assert :skip = ClientFS.maybe_read(%{conversation_id: conv_id}, ws, path, [])
    end

    test "without the client capability, or for another workspace kind, nothing is asked", %{
      server: server
    } do
      {sid, _, _} = new_session(server)

      assert :skip =
               ClientFS.maybe_read(
                 %{conversation_id: conv_of(sid)},
                 %SuperPi.Env.Workspace{kind: "local"},
                 Path.join(File.cwd!(), "mix.exs"),
                 []
               )

      assert :skip =
               ClientFS.maybe_read(
                 %{conversation_id: conv_of(sid)},
                 %SuperPi.Env.Workspace{kind: "shared"},
                 Path.join(File.cwd!(), "mix.exs"),
                 []
               )

      assert :skip = ClientFS.maybe_read(%{}, %SuperPi.Env.Workspace{kind: "local"}, "/x", [])
    end
  end
end
