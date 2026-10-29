defmodule SuperPi.Gateway.RouterMoreDefectsTest do
  @moduledoc """
  Regression tests for further gateway router and server defects found in the code
  review. Every test is expected to FAIL on the current code and pass once the
  matching finding is fixed.

  Run only these:  mix test --only known_bug
  Skip these:      mix test --exclude known_bug
  """
  use SuperPi.DataCase, async: false

  import Plug.Conn
  import Plug.Test
  import ExUnit.CaptureLog

  alias SuperPi.Conversation.Machine
  alias SuperPi.Durable.Schemas.Conversation
  alias SuperPi.Durable.Schemas.Entry
  alias SuperPi.Durable.Storage
  alias SuperPi.Gateway.Router
  alias SuperPi.TestSupport.Faults

  @opts Router.init([])


  defmodule HandledExtension do
    @moduledoc false
    use SuperPi.Extension

    @impl true
    def on_input(_input, _ctx), do: :handled
  end

  defmodule HandledHarness do
    @moduledoc false
    @behaviour SuperPi.Harness

    @impl true
    def id, do: "router-more-handled"
    @impl true
    def name, do: "Handled"
    @impl true
    def description, do: "test harness whose extension swallows input"
    @impl true
    def extensions(_opts), do: [SuperPi.Gateway.RouterMoreDefectsTest.HandledExtension]
    @impl true
    def agent_defaults(opts), do: SuperPi.Harness.Default.agent_defaults(opts)
  end

  setup do
    SuperPi.Tools.ensure_catalog_ets!()
    Router.ensure_session_cache!()
    :ok
  end

  defp post(body, headers \\ [], adapter_wrap \\ & &1) do
    raw = if is_binary(body), do: body, else: Jason.encode!(body)

    conn =
      conn(:post, "/v1/chat/completions", raw)
      |> put_req_header("content-type", "application/json")

    headers
    |> Enum.reduce(conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    |> adapter_wrap.()
    |> Router.call(@opts)
  rescue
    e -> {:raised, e}
  catch
    :exit, reason -> {:exited, reason}
  end

  defp chat(messages, extra \\ %{}) do
    Map.merge(%{"model" => "super-pi-agent", "messages" => messages}, extra)
  end

  defp user(text), do: %{"role" => "user", "content" => text}

  defp sse_frames(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, "data: "))
    |> Enum.map(fn "data: " <> p -> p end)
  end

  defp sse_json(body) do
    body |> sse_frames() |> Enum.reject(&(&1 == "[DONE]")) |> Enum.map(&Jason.decode!/1)
  end

  defp last_conversation_id do
    Repo.one(from c in Conversation, order_by: [desc: c.id], limit: 1, select: c.id)
  end

  defp entries(conv_id) do
    Repo.all(from e in Entry, where: e.conversation_id == ^conv_id and e.kind == "pi.message", order_by: e.seq)
  end

  defp start_machine(conv, opts) do
    {:ok, pid} = Machine.start_link([conversation_id: conv.id] ++ opts)
    pid
  end

  # --- Finding 1: machine lifecycle ---

  describe "machine supervision (router.ex:400-410)" do
    test "the machine is not a child of the request process" do
      assert %Plug.Conn{status: 200} = post(chat([user("hi")]))

      conv_id = last_conversation_id()
      [{pid, _}] = Registry.lookup(SuperPi.Registry, {:conversation_machine, conv_id})
      {:dictionary, dict} = Process.info(pid, :dictionary)
      ancestors = Keyword.get(dict, :"$ancestors", [])

      refute self() in ancestors,
             "machine was started with start_link from the request process; it dies with the request and is unsupervised"
    end
  end

  # --- Finding 2: turn errors ---

  describe "turn failures (router.ex:414-465,639-646)" do
    test "streaming: a failing turn is reported as an error, not an empty successful stop" do
      conv = Storage.create_conversation!()
      start_machine(conv, llm_responder: fn _p, _c -> {:error, :provider_exploded} end)

      conn = post(chat([user("hi")], %{"stream" => true}), [{"x-conversation-id", to_string(conv.id)}])
      assert %Plug.Conn{} = conn

      frames = sse_json(conn.resp_body)

      assert Enum.any?(frames, &Map.has_key?(&1, "error")) or
               Enum.any?(frames, fn f -> match?(%{"choices" => [%{"finish_reason" => r} | _]} when r not in [nil, "stop"], f) end),
             "client saw an empty success; frames: #{inspect(conn.resp_body)}"
    end

    test "streaming: a crashed machine is reported as an error, not a clean stop" do
      Process.flag(:trap_exit, true)
      conv = Storage.create_conversation!()

      start_machine(conv,
        llm_responder: fn _p, _c ->
          [{pid, _}] = Registry.lookup(SuperPi.Registry, {:conversation_machine, conv.id})
          Process.exit(pid, :kill)
          {:error, :unreachable}
        end
      )

      conn = post(chat([user("hi")], %{"stream" => true}), [{"x-conversation-id", to_string(conv.id)}])
      assert %Plug.Conn{} = conn

      frames = sse_json(conn.resp_body)

      assert Enum.any?(frames, &Map.has_key?(&1, "error")),
             "worker :DOWN was treated as success; body: #{inspect(conn.resp_body)}"
    end

    test "sync: a machine that dies mid-turn yields an error response, not an uncaught exit" do
      Process.flag(:trap_exit, true)
      conv = Storage.create_conversation!()

      start_machine(conv,
        llm_responder: fn _p, _c ->
          [{pid, _}] = Registry.lookup(SuperPi.Registry, {:conversation_machine, conv.id})
          Process.exit(pid, :kill)
          {:error, :unreachable}
        end
      )

      result = post(chat([user("hi")]), [{"x-conversation-id", to_string(conv.id)}])

      case result do
        {:exited, reason} -> flunk("Machine.submit exit escaped the router: #{inspect(reason)}")
        %Plug.Conn{status: status} -> assert status in 500..599
      end
    end

    test "sync: an input swallowed by an extension does not leak :handled_by_extension as content" do
      Application.put_env(:super_pi, :extra_harnesses, [HandledHarness])
      on_exit(fn -> Application.delete_env(:super_pi, :extra_harnesses) end)

      conn = post(chat([user("hi")], %{"model" => "Elixir.SuperPi.Gateway.RouterMoreDefectsTest.HandledHarness"}))
      case conn do
        {:raised, e} ->
          flunk("router crashed on {:ok, :handled_by_extension}: #{Exception.message(e)}")

        %Plug.Conn{status: 200} ->
          content = Jason.decode!(conn.resp_body)["choices"] |> hd() |> get_in(["message", "content"])
          refute content =~ "handled_by_extension", "internal atom leaked to the client: #{inspect(content)}"

        %Plug.Conn{} ->
          :ok
      end
    end
  end

  # --- Finding 3: tool progress ---

  describe "tool progress in SSE (router.ex:564-615)" do
    test "reasoning_content shows the real tool arguments, not {}" do
      conv = Storage.create_conversation!()

      start_machine(conv,
        llm_responder: Faults.tool_then_text_responder("bash", %{"command" => "echo marker-cmd-123"}, "done"),
        tool_executor: fn _n, _a, _c -> %{"output" => "ok", "is_error" => false} end
      )

      conn = post(chat([user("run")], %{"stream" => true}), [{"x-conversation-id", to_string(conv.id)}])
      assert conn.status == 200

      reasoning =
        conn.resp_body
        |> sse_json()
        |> Enum.map(fn
          %{"choices" => [%{"delta" => %{"reasoning_content" => r}} | _]} -> r
          _ -> ""
        end)
        |> Enum.join()

      assert reasoning =~ "echo marker-cmd-123", "preview lost the arguments: #{inspect(reasoning)}"
    end

    test "non-string tool arguments and output do not crash the SSE handler" do
      conv = Storage.create_conversation!()

      responder = fn _payload, _ctx ->
        topic = "conversation:#{conv.id}"
        weird = %{"command" => %{"nested" => 1}, "path" => ["a"], "query" => 5}

        for ev <- [
              %{"type" => "tool_started", "name" => "x", "args" => weird, "arguments" => weird},
              %{"type" => "tool_completed", "name" => "x", "output" => %{"a" => 1}, "is_error" => false}
            ] do
          Phoenix.PubSub.broadcast(SuperPi.PubSub, topic, {:conversation_event, conv.id, ev})
        end

        {:ok, Faults.text_msg("fine")}
      end

      start_machine(conv, llm_responder: responder)

      result = post(chat([user("go")], %{"stream" => true}), [{"x-conversation-id", to_string(conv.id)}])

      case result do
        {:raised, e} -> flunk("SSE handler crashed on a non-string field: #{Exception.message(e)}")
        {:exited, r} -> flunk("SSE handler exited: #{inspect(r)}")
        %Plug.Conn{} = conn -> assert conn.resp_body =~ "[DONE]"
      end
    end
  end

  # --- Finding 4: seeding ---

  describe "seeding prior messages (router.ex:77-104,352-367)" do
    test "the last user prompt is stored exactly once when the final message is not a user message" do
      messages = [user("first-question"), %{"role" => "assistant", "content" => "first-answer"}, user("second-question"), %{"role" => "assistant", "content" => "tail-answer"}]

      assert %Plug.Conn{status: 200} = post(chat(messages))

      texts = last_conversation_id() |> entries() |> Enum.map(&inspect(&1.data))
      count = Enum.count(texts, &(&1 =~ "second-question" and not (&1 =~ "Echo")))
      assert count == 1, "second-question stored #{count} times (seeded and resubmitted)"
      assert Enum.any?(texts, &(&1 =~ "tail-answer")), "the trailing assistant message was dropped"
    end

    test "tool messages and assistant tool calls from the client history are preserved" do
      messages = [
        user("list files"),
        %{
          "role" => "assistant",
          "content" => nil,
          "tool_calls" => [%{"id" => "call_9", "type" => "function", "function" => %{"name" => "bash", "arguments" => "{\"command\":\"ls\"}"}}]
        },
        %{"role" => "tool", "tool_call_id" => "call_9", "content" => "file-one.txt"},
        user("thanks")
      ]

      assert %Plug.Conn{status: 200} = post(chat(messages))

      data = last_conversation_id() |> entries() |> Enum.map(& &1.data)
      assert Enum.any?(data, &(&1["role"] == "tool")), "tool result was dropped from seeded history"
      assert Enum.any?(data, &(inspect(&1) =~ "call_9" and &1["role"] == "assistant")), "assistant tool call was dropped"
    end
  end

  # --- Finding 5: SSE shape and usage ---

  describe "SSE shape and usage (router.ex:226-264,420-431,661-701)" do
    test "the first chunk carries the assistant role delta" do
      conn = post(chat([user("hi")], %{"stream" => true}))
      [first | _] = sse_json(conn.resp_body)
      assert get_in(first, ["choices", Access.at(0), "delta", "role"]) == "assistant"
    end

    test "usage is reported on exactly one chunk" do
      conn = post(chat([user("hi")], %{"stream" => true}))
      with_usage = conn.resp_body |> sse_json() |> Enum.count(&Map.has_key?(&1, "usage"))
      assert with_usage == 1, "usage present on #{with_usage} chunks (double counting)"
    end

    test "title responses do not report fabricated token counts" do
      body = chat([%{"role" => "system", "content" => "You are a title generator"}, user("hello")])
      conn = post(body)
      usage = Jason.decode!(conn.resp_body)["usage"]
      refute usage["prompt_tokens"] == 35 and usage["completion_tokens"] == 8, "title usage is hard-coded 35/8"
    end

    test "stream usage does not reuse the previous turn's counts when this turn reports none" do
      conv = Storage.create_conversation!()
      counter = :counters.new(1, [])

      responder = fn _p, _c ->
        :counters.add(counter, 1, 1)

        if :counters.get(counter, 1) == 1 do
          {:ok, Map.put(Faults.text_msg("one"), "usage", %{"input_tokens" => 111, "output_tokens" => 222})}
        else
          {:ok, Faults.text_msg("two")}
        end
      end

      start_machine(conv, llm_responder: responder)
      headers = [{"x-conversation-id", to_string(conv.id)}]

      post(chat([user("a")], %{"stream" => true}), headers)
      conn = post(chat([user("b")], %{"stream" => true}), headers)

      usage = conn.resp_body |> sse_json() |> Enum.find_value(& &1["usage"])
      refute usage["prompt_tokens"] == 111, "turn 2 reported turn 1 usage: #{inspect(usage)}"
    end
  end

  # --- Finding 6: title hijack ---

  describe "title detection (router.ex:66-70,160-168)" do
    test "a system prompt that merely mentions 'title generator' still runs the agent" do
      body = chat([%{"role" => "system", "content" => "You are a coding agent. Never act as a title generator for PRs."}, user("real question")])
      conn = post(body)
      content = Jason.decode!(conn.resp_body)["choices"] |> hd() |> get_in(["message", "content"])
      assert content == "Echo: real question", "agent turn was hijacked: #{inspect(content)}"
    end

    test "a user message that starts with 'generate a title' runs the agent when a system prompt is present" do
      body = chat([%{"role" => "system", "content" => "You are a coding agent."}, user("Generate a title case function in Elixir")])
      conn = post(body)
      content = Jason.decode!(conn.resp_body)["choices"] |> hd() |> get_in(["message", "content"])
      assert content == "Echo: Generate a title case function in Elixir", "agent turn was hijacked: #{inspect(content)}"
    end
  end

  # --- Finding 7: disconnects ---

  defmodule ClosedAdapter do
    @moduledoc false
    # Plug.Test adapter whose chunk/2 reports a closed socket.
    alias Plug.Adapters.Test.Conn, as: T

    defdelegate send_resp(s, st, h, b), to: T
    defdelegate send_file(s, st, h, f, o, l), to: T
    defdelegate send_chunked(s, st, h), to: T
    defdelegate read_req_body(s, o), to: T
    defdelegate inform(s, st, h), to: T
    defdelegate upgrade(s, p, o), to: T
    defdelegate push(s, p, h), to: T
    defdelegate get_peer_data(s), to: T
    defdelegate get_http_protocol(s), to: T
    def chunk(_state, _data), do: {:error, :closed}
  end

  defp closed_adapter(conn) do
    {_mod, state} = conn.adapter
    %{conn | adapter: {ClosedAdapter, state}}
  end

  describe "client disconnect (router.ex:226-264,489-500)" do
    test "title streaming does not raise MatchError when the client is gone" do
      body = chat([%{"role" => "system", "content" => "You are a title generator"}, user("hello")], %{"stream" => true})

      case post(body, [], &closed_adapter/1) do
        {:raised, e} -> flunk("router raised #{inspect(e.__struct__)} on a closed connection")
        %Plug.Conn{} -> :ok
      end
    end

    test "the turn is cancelled when the client disconnects mid-stream" do
      conv = Storage.create_conversation!()
      test_pid = self()

      responder = fn _p, ctx ->
        ctx[:emit_event].(%{"type" => "text_delta", "index" => 0, "delta" => "partial"})
        Process.sleep(400)
        send(test_pid, :turn_ran_to_completion)
        {:ok, Faults.text_msg("partial")}
      end

      start_machine(conv, llm_responder: responder)

      assert %Plug.Conn{} = post(chat([user("hi")], %{"stream" => true}), [{"x-conversation-id", to_string(conv.id)}], &closed_adapter/1)

      refute_receive :turn_ran_to_completion, 800, "turn kept running after the client disconnected"
    end
  end

  # --- Finding 8: authentication ---

  describe "gateway exposure (server.ex)" do
    test "binding a non-loopback address without a configured token is refused" do
      result =
        try do
          {:built, SuperPi.Gateway.Server.child_spec(ip: {0, 0, 0, 0}, port: 0)}
        rescue
          e -> {:refused, e}
        end

      assert {:refused, _} = result, "child_spec accepted 0.0.0.0 with no authentication token"
    end
  end

  # --- Finding 16: logging ---

  describe "log hygiene (router.ex:74,115,566)" do
    setup do
      old = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: old) end)
    end

    test "user prompt text is not written to the info log" do
      log = capture_log([level: :info], fn -> post(chat([user("my password is hunter2-secret-prompt")])) end)
      refute log =~ "hunter2-secret-prompt"
    end

    test "tool arguments such as written file contents are not written to the info log" do
      conv = Storage.create_conversation!()

      responder = fn _p, _c ->
        ev = %{"type" => "tool_started", "name" => "write", "args" => %{"path" => "a", "content" => "FILE-SECRET-BODY"}, "arguments" => %{"path" => "a", "content" => "FILE-SECRET-BODY"}}
        Phoenix.PubSub.broadcast(SuperPi.PubSub, "conversation:#{conv.id}", {:conversation_event, conv.id, ev})
        {:ok, Faults.text_msg("ok")}
      end

      start_machine(conv, llm_responder: responder)

      log =
        capture_log([level: :info], fn ->
          post(chat([user("go")], %{"stream" => true}), [{"x-conversation-id", to_string(conv.id)}])
        end)

      refute log =~ "FILE-SECRET-BODY"
    end
  end
end
