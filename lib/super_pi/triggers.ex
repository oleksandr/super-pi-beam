defmodule SuperPi.Triggers do
  @moduledoc """
  Webhook triggers: `POST /v1/triggers/:token`.

  A third party gets a scoped secret that wakes exactly one schedule (`kind: "webhook"`). The
  token is not the gateway bearer token. Only its SHA-256 is stored, and it is compared in
  constant time (`Plug.Crypto.secure_compare/2`). The route runs before the JSON parser and
  reads its own body, so nobody reaches a parser or a limit without a valid token, and the
  body cap is enforced while reading.

  | Answer | Meaning |
  |---|---|
  | `202` | Queued. The sender never waits for an LLM turn. |
  | `401` | Unknown, cancelled or paused trigger. One answer for all three, so a token cannot be probed. |
  | `400` | Body is not valid UTF-8. |
  | `413` | Body is larger than `config :super_pi, :trigger_max_bytes` (default 32768). |

  The body is put into the schedule's prompt, fenced and marked as data from an outside sender
  (`{{payload}}` in the prompt marks the place, else it is appended). It is untrusted input to
  an unattended agent: give a webhook schedule a prompt and a harness that cannot do harm with it.

  An `Idempotency-Key` header (up to 200 printable characters) is the second half of the unique job
  key, so a retried delivery is a no-op for as long as Oban keeps the job (24 h with the default
  `Pruner`). Without it every delivery is a new run.

  Each accepted delivery adds a note (payload, truncated) to `pi.inbox` of the owning conversation.

  Webhooks exist only where a harness opts in: `Plugins.Scheduler` creates a webhook schedule only
  when its config has `allow_webhooks: true` (default `false`). Spending money from an endpoint
  that is not behind the bearer token has to be a deliberate choice.
  """

  import Plug.Conn

  alias SuperPi.Schedule
  alias SuperPi.Workers.ScheduleRunWorker

  @default_max_bytes 32_768
  @max_key_chars 200
  @note_payload_chars 500

  @doc "Maximum body size in bytes."
  def max_bytes, do: Application.get_env(:super_pi, :trigger_max_bytes, @default_max_bytes)

  @doc """
  Handles a delivery for `token`. Reads the body itself, so call it before `Plug.Parsers`.
  Always answers; returns the conn.
  """
  @spec handle(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def handle(conn, token) do
    case Schedule.find_webhook(token) do
      nil -> reply(conn, 401, "invalid_trigger", "Unknown or inactive trigger.")
      schedule -> deliver(conn, schedule)
    end
  end

  defp deliver(conn, schedule) do
    case read_capped(conn) do
      {:ok, body, conn} ->
        with true <- String.valid?(body) or {:error, :bad_body},
             {:ok, key} <- idempotency_key(conn) do
          enqueue(conn, schedule, body, key)
        else
          {:error, :bad_body} -> reply(conn, 400, "invalid_body", "Body must be UTF-8 text.")
          {:error, :bad_key} -> reply(conn, 400, "invalid_idempotency_key", "Idempotency-Key must be printable text of at most #{@max_key_chars} characters.")
        end

      {:error, :too_large, conn} ->
        reply(conn, 413, "payload_too_large", "Body is larger than #{max_bytes()} bytes.")

      {:error, :bad_body, conn} ->
        reply(conn, 400, "invalid_body", "Could not read the body.")
    end
  end

  defp read_capped(conn) do
    cap = max_bytes()

    case read_body(conn, length: cap, read_length: min(cap, 8_192)) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _partial, conn} -> {:error, :too_large, conn}
      {:error, _} -> {:error, :bad_body, conn}
    end
  end

  defp idempotency_key(conn) do
    case get_req_header(conn, "idempotency-key") do
      [] -> {:ok, nil}
      [key | _] -> if valid_key?(key), do: {:ok, key}, else: {:error, :bad_key}
    end
  end

  defp valid_key?(key), do: key != "" and String.length(key) <= @max_key_chars and String.printable?(key)

  defp enqueue(conn, s, body, key) do
    now = DateTime.utc_now()

    # A delivery without a key is always a new run, so its job key is unique by construction.
    fire_at = if key, do: "key:" <> key, else: "hook:" <> DateTime.to_iso8601(now) <> ":" <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

    args = %{"schedule_id" => s.id, "fire_at" => fire_at, "payload" => body, "received_at" => DateTime.to_iso8601(now)}

    case args |> ScheduleRunWorker.new() |> Oban.insert() do
      {:ok, %Oban.Job{conflict?: true}} ->
        reply(conn, 202, "duplicate", "Already accepted.")

      {:ok, _job} ->
        Schedule.note!(s.conversation_id, %{
          "kind" => "trigger",
          "schedule_id" => s.id,
          "idempotency_key" => key,
          "text" => "Trigger of schedule #{s.id} accepted.",
          "payload" => String.slice(body, 0, @note_payload_chars)
        })

        reply(conn, 202, "accepted", "Queued.")

      {:error, _} ->
        reply(conn, 503, "unavailable", "Could not queue the run. Retry.")
    end
  end

  defp reply(conn, status, code, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{"status" => code, "message" => message}))
  end
end
