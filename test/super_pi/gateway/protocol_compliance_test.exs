defmodule SuperPi.Gateway.ProtocolComplianceTest do
  @moduledoc """
  Comprehensive OpenAI-Compatible Gateway Protocol Compliance Test Suite.
  Verifies:
  - Multi-turn keep-alive invariance (no PubSub multiplication or chunk duplication)
  - Strict SSE chunk framing and termination protocol
  - Dedicated usage metadata chunks for @ai-sdk / OpenCode status bar
  - Interim tool progress streaming via reasoning_content without polluting message content
  - Accurate model discovery and harness registration
  """

  use SuperPi.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias SuperPi.Gateway.Router

  @opts Router.init([])

  setup do
    SuperPi.Tools.ensure_catalog_ets!()
    Router.ensure_session_cache!()
    :ok
  end

  describe "Multi-Turn Keep-Alive Invariance (Anti-Duplication Protocol)" do
    test "consecutive streaming turns over a persistent connection process never multiply chunks" do
      session_id = "keepalive-multi-turn-#{Uniq.UUID.uuid7()}"

      # Execute 5 consecutive turns simulating a persistent keep-alive client connection
      for turn <- 1..5 do
        prompt = "Turn #{turn} prompt"

        payload = %{
          "model" => "super-pi-fast",
          "messages" => [
            %{"role" => "user", "content" => prompt}
          ],
          "stream" => true
        }

        conn =
          conn(:post, "/v1/chat/completions", Jason.encode!(payload))
          |> put_req_header("content-type", "application/json")
          |> put_req_header("x-session-id", session_id)
          |> Router.call(@opts)

        assert conn.status == 200
        raw_body = conn.resp_body

        # 1. Framing: Must contain exactly one termination marker [DONE]
        done_matches = Regex.scan(~r/data: \[DONE\]/, raw_body)
        assert length(done_matches) == 1, "Turn #{turn} emitted multiple [DONE] markers"

        # 2. Stop Reason: Exactly one finish_reason: "stop" chunk
        stop_matches = Regex.scan(~r/"finish_reason":"stop"/, raw_body)
        assert length(stop_matches) == 1, "Turn #{turn} emitted #{length(stop_matches)} stop chunks (expected exactly 1)"

        # 3. Usage Chunk: Exactly one choices: [] chunk
        empty_choice_matches = Regex.scan(~r/"choices":\[\]/, raw_body)
        assert length(empty_choice_matches) == 1, "Turn #{turn} emitted #{length(empty_choice_matches)} choices: [] chunks"

        # 4. Content Reconstruction: Extract all delta.content chunks and concatenate
        reconstructed =
          raw_body
          |> String.split("\n\n")
          |> Enum.filter(&String.starts_with?(&1, "data: {"))
          |> Enum.map(fn "data: " <> json ->
            case Jason.decode!(json) do
              %{"choices" => [%{"delta" => %{"content" => c}} | _]} when is_binary(c) -> c
              _ -> ""
            end
          end)
          |> Enum.join("")

        # In offline/mock mode, reply is "Echo: Turn X prompt"
        # In live mode, reply is direct answer.
        # Regardless of mode, the text must NOT repeat or duplicate chunks!
        expected_echo = "Echo: #{prompt}"
        if reconstructed == expected_echo do
          # Exact match: zero duplication!
          assert reconstructed == expected_echo
        else
          # Live model: ensure the string is not duplicated back-to-back (e.g. "Ready.Ready.")
          half_len = div(String.length(reconstructed), 2)
          if half_len > 10 do
            first_half = String.slice(reconstructed, 0, half_len)
            second_half = String.slice(reconstructed, half_len, half_len)
            refute first_half == second_half, "Turn #{turn} output appears duplicated back-to-back: #{inspect(reconstructed)}"
          end
        end
      end
    end
  end

  describe "OpenAI SSE Specification Compliance" do
    test "SSE chunks conform strictly to chat.completion.chunk schema" do
      payload = %{
        "model" => "super-pi-agent",
        "messages" => [%{"role" => "user", "content" => "Schema verification"}],
        "stream" => true
      }

      conn =
        conn(:post, "/v1/chat/completions", Jason.encode!(payload))
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["text/event-stream"]
      assert get_resp_header(conn, "cache-control") == ["no-cache"]
      assert get_resp_header(conn, "connection") == ["keep-alive"]

      lines = String.split(conn.resp_body, "\n\n")
      json_chunks =
        lines
        |> Enum.filter(&String.starts_with?(&1, "data: {"))
        |> Enum.map(fn "data: " <> json -> Jason.decode!(json) end)

      assert json_chunks != []

      # Verify all chunks share consistent ID, model, and object type
      [first_chunk | _] = json_chunks
      completion_id = first_chunk["id"]
      assert String.starts_with?(completion_id, "chatcmpl-")
      assert first_chunk["object"] == "chat.completion.chunk"
      assert is_integer(first_chunk["created"])

      for chunk <- json_chunks do
        assert chunk["id"] == completion_id
        assert chunk["object"] == "chat.completion.chunk"
        assert chunk["model"] == "super-pi-agent"
      end

      # Verify dedicated usage chunk exists with valid integer fields
      usage_chunk = Enum.find(json_chunks, &(&1["choices"] == [] and is_map(&1["usage"])))
      assert usage_chunk != nil
      assert is_integer(usage_chunk["usage"]["prompt_tokens"])
      assert is_integer(usage_chunk["usage"]["completion_tokens"])
      assert is_integer(usage_chunk["usage"]["total_tokens"])
      assert usage_chunk["usage"]["total_tokens"] ==
               usage_chunk["usage"]["prompt_tokens"] + usage_chunk["usage"]["completion_tokens"]
    end
  end

  describe "Interim Tool Progress & Reasoning Visibility" do
    test "streams tool execution status into reasoning_content without polluting response content" do
      conv = SuperPi.Durable.Storage.create_conversation!()

      responder = fn payload, ctx ->
        has_tool? = Enum.any?(payload.messages, &(&1["role"] == "tool"))

        if not has_tool? do
          {:ok,
           %{
             "role" => "assistant",
             "content" => [
               %{"type" => "tool_call", "id" => "c1", "name" => "bash", "arguments" => %{"command" => "curl -s https://api.weather.com"}}
             ]
           }}
        else
          text = "Sunny +21C"
          if is_function(ctx[:emit_event], 1) do
            ctx[:emit_event].(%{"type" => "text_delta", "index" => 0, "delta" => text})
          end

          {:ok,
           %{
             "role" => "assistant",
             "content" => [%{"type" => "text", "text" => text}]
           }}
        end
      end

      executor = fn _name, _args, _ctx ->
        %{"output" => "temp: 21C", "is_error" => false}
      end

      # Pre-start machine with custom responder and executor
      {:ok, _pid} =
        SuperPi.Conversation.Machine.start_link(
          conversation_id: conv.id,
          llm_responder: responder,
          tool_executor: executor
        )

      payload = %{
        "model" => "super-pi-agent",
        "messages" => [%{"role" => "user", "content" => "Check weather"}],
        "stream" => true
      }

      conn =
        conn(:post, "/v1/chat/completions", Jason.encode!(payload))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-conversation-id", to_string(conv.id))
        |> Router.call(@opts)

      assert conn.status == 200
      raw_body = conn.resp_body

      # Extract all reasoning_content chunks
      reasoning_text =
        raw_body
        |> String.split("\n\n")
        |> Enum.filter(&String.starts_with?(&1, "data: {"))
        |> Enum.map(fn "data: " <> json ->
          case Jason.decode!(json) do
            %{"choices" => [%{"delta" => %{"reasoning_content" => r}} | _]} when is_binary(r) -> r
            _ -> ""
          end
        end)
        |> Enum.join("")

      # Verify tool progress is visible in reasoning_content
      assert String.contains?(reasoning_text, "Executing bash")
      assert String.contains?(reasoning_text, "bash completed")

      # Extract main content and verify tool progress did NOT bleed into text
      content_text =
        raw_body
        |> String.split("\n\n")
        |> Enum.filter(&String.starts_with?(&1, "data: {"))
        |> Enum.map(fn "data: " <> json ->
          case Jason.decode!(json) do
            %{"choices" => [%{"delta" => %{"content" => c}} | _]} when is_binary(c) -> c
            _ -> ""
          end
        end)
        |> Enum.join("")

      assert String.contains?(content_text, "Sunny +21C")
      refute String.contains?(content_text, "Executing bash")
      refute String.contains?(content_text, "bash completed")
    end
  end

  describe "Model Discovery & Harness Directory" do
    test "GET /v1/models exposes all built-in harnesses" do
      conn =
        conn(:get, "/v1/models")
        |> Router.call(@opts)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["object"] == "list"

      ids = Enum.map(body["data"], & &1["id"])
      expected = [
        "super-pi-agent",
        "super-pi-fast",
        "super-pi-auto",
        "super-pi-interactive",
        "super-pi-workspace",
        "super-pi-planner"
      ]

      for exp_id <- expected do
        assert exp_id in ids, "Missing expected harness model '#{exp_id}' in /v1/models"
      end
    end
  end
end
