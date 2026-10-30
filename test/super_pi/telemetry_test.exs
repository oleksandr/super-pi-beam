defmodule SuperPi.TelemetryTest do
  @moduledoc "OpenTelemetry spans and Prometheus metrics for turns, provider calls, tools and gateway requests."
  use SuperPi.DataCase, async: false
  import Plug.Test
  import Plug.Conn
  require Record

  alias SuperPi.Conversation.Machine
  alias SuperPi.Durable.Storage
  alias SuperPi.Gateway.Router
  alias SuperPi.TestSupport.Faults

  Record.defrecord(:span, Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl"))

  Record.defrecord(
    :status,
    Record.extract(:status, from_lib: "opentelemetry_api/include/opentelemetry.hrl")
  )

  setup do
    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
    :ok
  end

  # Collects every exported span until none arrives for `quiet` ms.
  defp spans(quiet \\ 300) do
    receive do
      {:span, s} -> [s | spans(quiet)]
    after
      quiet -> []
    end
  end

  defp name(s), do: span(s, :name)
  defp attrs(s), do: s |> span(:attributes) |> :otel_attributes.map()
  defp by_name(spans, prefix), do: Enum.filter(spans, &String.starts_with?(name(&1), prefix))

  defp status_code(s) do
    case span(s, :status) do
      :undefined -> :unset
      st -> status(st, :code)
    end
  end

  defp parent(s), do: span(s, :parent_span_id)
  defp id(s), do: span(s, :span_id)
  defp trace(s), do: span(s, :trace_id)

  defp usage_msg(text, in_tok, out_tok),
    do:
      Map.put(Faults.text_msg(text), "usage", %{
        "input_tokens" => in_tok,
        "output_tokens" => out_tok
      })

  defp run_turn(responder, opts \\ []) do
    conv = Storage.create_conversation!(agent: %{"model" => "test-model"})

    {:ok, pid} =
      Machine.start_link(
        [conversation_id: conv.id, extensions: [], llm_responder: responder] ++
          Keyword.take(opts, [:tool_executor])
      )

    result = Machine.submit(pid, "my secret prompt text", timeout: 10_000)
    {conv, result}
  end

  describe "turn, provider and tool spans" do
    test "a turn with a tool call produces a linked tree" do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      responder = fn _p, _c ->
        case Agent.get_and_update(calls, &{&1, &1 + 1}) do
          0 ->
            {:ok,
             Map.put(Faults.tool_call_msg("t1", "read", %{"path" => "mix.exs"}), "usage", %{
               "input_tokens" => 10,
               "output_tokens" => 3
             })}

          _ ->
            {:ok, usage_msg("done", 20, 5)}
        end
      end

      {conv, {:ok, _}} = run_turn(responder, tool_executor: &Faults.plain_tool_executor/3)
      all = spans()

      [turn] = by_name(all, "super_pi.turn")
      llm = by_name(all, "chat test-model")
      [tool] = by_name(all, "execute_tool read")

      assert length(llm) == 2
      assert attrs(turn)["super_pi.conversation.id"] == conv.id

      for child <- llm ++ [tool] do
        assert parent(child) == id(turn)
        assert trace(child) == trace(turn)
      end

      assert llm
             |> Enum.map(&attrs/1)
             |> Enum.map(& &1["gen_ai.usage.input_tokens"])
             |> Enum.sort() == [10, 20]

      assert attrs(tool)["gen_ai.tool.name"] == "read"
      assert attrs(tool)["super_pi.tool.error"] == false
      assert status_code(turn) == :unset
    end

    test "a failing provider call marks the provider span and the turn as errors" do
      {_conv, {:error, _}} = run_turn(fn _p, _c -> {:error, "provider down"} end)
      all = spans()

      [turn] = by_name(all, "super_pi.turn")
      assert status_code(turn) == :error
      assert Enum.all?(by_name(all, "chat "), &(status_code(&1) == :error))
    end

    test "a tool result with is_error marks the tool span" do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      responder = fn _p, _c ->
        case Agent.get_and_update(calls, &{&1, &1 + 1}) do
          0 -> {:ok, Faults.tool_call_msg("t1", "read", %{"path" => "x"})}
          _ -> {:ok, Faults.text_msg("done")}
        end
      end

      failing = fn _name, _args, _ctx -> %{"output" => "nope", "is_error" => true} end
      {_conv, {:ok, _}} = run_turn(responder, tool_executor: failing)

      [tool] = spans() |> by_name("execute_tool read")
      assert attrs(tool)["super_pi.tool.error"] == true
      assert status_code(tool) == :error
    end

    test "prompt text, answers and tool arguments are never recorded" do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      responder = fn _p, _c ->
        case Agent.get_and_update(calls, &{&1, &1 + 1}) do
          0 -> {:ok, Faults.tool_call_msg("t1", "read", %{"path" => "super-secret-path"})}
          _ -> {:ok, Faults.text_msg("super secret answer")}
        end
      end

      run_turn(responder, tool_executor: &Faults.plain_tool_executor/3)
      dump = spans() |> Enum.map(&inspect(attrs(&1))) |> Enum.join()

      for secret <- ["my secret prompt text", "super-secret-path", "super secret answer"] do
        refute dump =~ secret
      end
    end

    test "each turn is its own span and the conversation stays usable" do
      conv = Storage.create_conversation!()

      {:ok, pid} =
        Machine.start_link(
          conversation_id: conv.id,
          extensions: [],
          llm_responder: fn _p, _c -> {:ok, Faults.text_msg("ok")} end
        )

      {:ok, _} = Machine.submit(pid, "one", timeout: 10_000)
      {:ok, _} = Machine.submit(pid, "two", timeout: 10_000)

      turns = spans() |> by_name("super_pi.turn")
      assert length(turns) == 2
      assert length(Enum.uniq_by(turns, &id/1)) == 2
    end
  end

  describe "gateway" do
    @opts Router.init([])

    defp post_chat(headers \\ []) do
      body = %{
        "model" => "super-pi-workspace",
        "messages" => [%{"role" => "user", "content" => "hi"}]
      }

      conn(:post, "/v1/chat/completions", Jason.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-session-id", "otel-#{System.unique_integer([:positive])}")
      |> then(fn c ->
        Enum.reduce(headers, c, fn {k, v}, acc -> put_req_header(acc, k, v) end)
      end)
      |> Router.call(@opts)
    end

    test "the request span is the parent of the turn span" do
      conn = post_chat()
      assert conn.status == 200
      all = spans(500)

      [request] =
        by_name(all, "super_pi.gateway.request")
        |> Enum.filter(&(attrs(&1)["url.path"] == "/v1/chat/completions"))

      [turn] = by_name(all, "super_pi.turn")

      assert attrs(request)["http.response.status_code"] == 200
      assert parent(turn) == id(request)
      assert trace(turn) == trace(request)
    end

    test "a rejected request has a span with the status code" do
      Application.put_env(:super_pi, :gateway_tokens, alice: "tok")
      on_exit(fn -> Application.delete_env(:super_pi, :gateway_tokens) end)

      assert conn(:get, "/v1/models") |> Router.call(@opts) |> Map.fetch!(:status) == 401
      [request] = spans() |> by_name("super_pi.gateway.request")
      assert attrs(request)["http.response.status_code"] == 401
    end
  end

  describe "metrics" do
    test "a turn is counted with its tokens and duration" do
      run_turn(fn _p, _c -> {:ok, usage_msg("ok", 7, 2)} end)

      text = SuperPi.Telemetry.scrape()
      assert text =~ ~r/super_pi_turn_total\{status="ok"\} \d+/
      assert text =~ ~r/super_pi_llm_requests_total\{model="other",status="ok"\} \d+/
      assert text =~ ~r/super_pi_llm_input_tokens\{model="other"\} \d+/
      assert text =~ "super_pi_llm_duration_milliseconds_bucket"
    end

    test "/metrics serves the text format, and needs a key when tokens are configured" do
      conn = conn(:get, "/metrics") |> Router.call(@opts)
      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> hd() =~ "text/plain"

      Application.put_env(:super_pi, :gateway_tokens, alice: "tok")
      on_exit(fn -> Application.delete_env(:super_pi, :gateway_tokens) end)

      assert conn(:get, "/metrics") |> Router.call(@opts) |> Map.fetch!(:status) == 401

      authed =
        conn(:get, "/metrics")
        |> put_req_header("authorization", "Bearer tok")
        |> Router.call(@opts)

      assert authed.status == 200
    end
  end
end
