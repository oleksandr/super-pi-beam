defmodule SuperPi.Telemetry do
  @moduledoc """
  Traces and metrics for conversations.

  ## Traces (OpenTelemetry)

  | Span | Where | Attributes |
  |---|---|---|
  | `super_pi.gateway.request` | each HTTP request | `http.request.method`, `url.path`, `http.response.status_code` |
  | `super_pi.turn` | one user submit, from input to idle | `super_pi.conversation.id`, `super_pi.task.id` |
  | `chat <model>` | one provider call | `gen_ai.request.model`, `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens` |
  | `execute_tool <name>` | one tool call | `gen_ai.tool.name`, `super_pi.tool.error` |

  A request span is the parent of the turn span, the turn span of its provider and tool spans.
  A span that fails has status `error` and the reason as its message.

  Spans are no-ops until an exporter is configured. Set `OTEL_EXPORTER_OTLP_ENDPOINT`
  (for example `http://localhost:4318`) and the app exports over OTLP/HTTP. The standard
  `OTEL_SERVICE_NAME` and `OTEL_RESOURCE_ATTRIBUTES` apply.

  ## Metrics (`:telemetry`, Prometheus)

  The same code emits `:telemetry` events: `[:super_pi, :turn | :llm | :tool, :stop]` with a
  `:duration` in native units, plus `:input_tokens` and `:output_tokens` for `:llm`.
  `metrics/0` defines counters, duration histograms and token sums over them. The gateway
  serves them at `GET /metrics` in Prometheus text format, behind the same authentication as
  the rest of the API.

  Prompt and completion text and tool arguments are never put in a span or a metric.
  """

  require OpenTelemetry.Tracer, as: Tracer
  alias OpenTelemetry.{Ctx, Span}
  import Telemetry.Metrics

  @type handle :: %{span: term(), token: term(), started: integer(), meta: map()}

  # --- Context propagation across processes ---

  @doc "The current trace context. Capture it before spawning a process that continues the work."
  def current_ctx, do: Ctx.get_current()

  @doc "Makes `ctx` current in this process. Pair it with `current_ctx/0`."
  def attach(nil), do: :ok
  def attach(ctx), do: Ctx.attach(ctx) && :ok

  # --- Spans that cross callbacks (the turn and the HTTP request) ---

  @doc """
  Starts a span, makes it current in this process, and returns a handle for `stop_span/3`.
  `parent` is a context from `current_ctx/0`, or `nil` for the current one.
  """
  @spec start_span(String.t(), map(), term()) :: handle()
  def start_span(name, attributes, parent \\ nil) do
    parent_ctx = parent || Ctx.get_current()
    span = Tracer.start_span(parent_ctx, name, %{attributes: attributes})
    token = parent_ctx |> Tracer.set_current_span(span) |> Ctx.attach()
    %{span: span, token: token, started: System.monotonic_time(), meta: attributes}
  end

  @doc """
  Ends the span and restores the previous context. `status` is `:ok` or `{:error, reason}`.
  Returns the duration in native time units. `attributes` are added before it ends.
  """
  def stop_span(%{span: span, token: token, started: started}, status \\ :ok, attributes \\ %{}) do
    if attributes != %{}, do: Span.set_attributes(span, Map.to_list(attributes))

    case status do
      :ok -> :ok
      {:error, reason} -> Span.set_status(span, OpenTelemetry.status(:error, format(reason)))
    end

    Span.end_span(span)
    Ctx.detach(token)
    System.monotonic_time() - started
  end

  # --- The conversation turn ---

  @doc "Starts the span for a turn. Call `turn_stop/2` when the conversation is idle again."
  def turn_start(conversation_id, task_id, parent_ctx \\ nil) do
    start_span(
      "super_pi.turn",
      %{"super_pi.conversation.id" => conversation_id, "super_pi.task.id" => task_id || 0},
      parent_ctx
    )
  end

  def turn_stop(nil, _status), do: :ok

  def turn_stop(handle, status) do
    duration = stop_span(handle, status)

    :telemetry.execute([:super_pi, :turn, :stop], %{duration: duration}, %{
      status: status_tag(status)
    })
  end

  # --- Spans inside one function (provider and tool calls) ---

  @doc """
  Runs `fun` inside a provider-call span. `fun` returns the responder's result, `{:ok, message}`
  or `{:error, reason}`. Token counts come from `message["usage"]`.
  """
  def llm_span(model, fun) do
    model = to_string(model)
    started = System.monotonic_time()

    Tracer.with_span "chat #{model}", %{
      attributes: %{"gen_ai.request.model" => model, "gen_ai.operation.name" => "chat"}
    } do
      result = fun.()
      {status, in_tok, out_tok} = describe_llm(result)

      Tracer.set_attributes(%{
        "gen_ai.usage.input_tokens" => in_tok,
        "gen_ai.usage.output_tokens" => out_tok
      })

      mark(status)

      :telemetry.execute(
        [:super_pi, :llm, :stop],
        %{
          duration: System.monotonic_time() - started,
          input_tokens: in_tok,
          output_tokens: out_tok
        },
        %{model: model_label(model), status: status_tag(status)}
      )

      result
    end
  end

  @doc "Runs `fun` inside a tool-call span. `fun` returns a tool result map; `\"is_error\"` marks failure."
  def tool_span(tool_name, fun) do
    tool = to_string(tool_name)
    started = System.monotonic_time()

    Tracer.with_span "execute_tool #{tool}", %{
      attributes: %{"gen_ai.tool.name" => tool, "gen_ai.operation.name" => "execute_tool"}
    } do
      result = fun.()
      error? = is_map(result) and Map.get(result, "is_error") == true
      Tracer.set_attributes(%{"super_pi.tool.error" => error?})
      if error?, do: mark({:error, "tool reported an error"})

      :telemetry.execute(
        [:super_pi, :tool, :stop],
        %{duration: System.monotonic_time() - started},
        %{tool: tool_label(tool), status: if(error?, do: "error", else: "ok")}
      )

      result
    end
  end

  # Metric labels come from fixed sets, so a client or a model cannot create new series by
  # inventing names. The span attributes keep the real value.
  defp tool_label(tool) do
    if :ets.whereis(:super_pi_tool_catalog) != :undefined and
         :ets.member(:super_pi_tool_catalog, tool),
       do: tool,
       else: "other"
  end

  defp model_label(model) do
    known = Enum.map(SuperPi.AI.Providers.catalog(), & &1["id"])
    if model in known or SuperPi.Harness.harness?(model), do: model, else: "other"
  end

  defp describe_llm({:ok, message}) when is_map(message) do
    usage = Map.get(message, "usage") || %{}
    {:ok, count(usage, "input_tokens"), count(usage, "output_tokens")}
  end

  defp describe_llm({:error, reason}), do: {{:error, reason}, 0, 0}
  defp describe_llm(_other), do: {:ok, 0, 0}

  defp count(usage, key) when is_map(usage) do
    case Map.get(usage, key) || Map.get(usage, String.to_atom(key)) do
      n when is_integer(n) and n >= 0 -> n
      _ -> 0
    end
  end

  defp mark(:ok), do: :ok
  defp mark({:error, reason}), do: Tracer.set_status(OpenTelemetry.status(:error, format(reason)))

  defp status_tag(:ok), do: "ok"
  defp status_tag(_), do: "error"

  defp format(reason) when is_binary(reason), do: String.slice(reason, 0, 200)
  defp format(reason), do: reason |> inspect() |> String.slice(0, 200)

  # --- Metrics ---

  @duration_buckets [10, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000, 30_000, 60_000]

  @doc "`Telemetry.Metrics` definitions for the events above."
  def metrics do
    ms = {:native, :millisecond}
    hist = [buckets: @duration_buckets]

    [
      counter("super_pi.turn.total",
        event_name: [:super_pi, :turn, :stop],
        measurement: :duration,
        tags: [:status]
      ),
      distribution("super_pi.turn.duration.milliseconds",
        event_name: [:super_pi, :turn, :stop],
        measurement: :duration,
        unit: ms,
        tags: [:status],
        reporter_options: hist
      ),
      counter("super_pi.llm.requests.total",
        event_name: [:super_pi, :llm, :stop],
        measurement: :duration,
        tags: [:model, :status]
      ),
      distribution("super_pi.llm.duration.milliseconds",
        event_name: [:super_pi, :llm, :stop],
        measurement: :duration,
        unit: ms,
        tags: [:model],
        reporter_options: hist
      ),
      sum("super_pi.llm.input.tokens",
        event_name: [:super_pi, :llm, :stop],
        measurement: :input_tokens,
        tags: [:model]
      ),
      sum("super_pi.llm.output.tokens",
        event_name: [:super_pi, :llm, :stop],
        measurement: :output_tokens,
        tags: [:model]
      ),
      counter("super_pi.tool.calls.total",
        event_name: [:super_pi, :tool, :stop],
        measurement: :duration,
        tags: [:tool, :status]
      ),
      distribution("super_pi.tool.duration.milliseconds",
        event_name: [:super_pi, :tool, :stop],
        measurement: :duration,
        unit: ms,
        tags: [:tool],
        reporter_options: hist
      )
    ]
  end

  @reporter :super_pi_metrics

  @doc "The Prometheus text exposition of the metrics, or an empty string if the reporter is not running."
  def scrape do
    TelemetryMetricsPrometheus.Core.scrape(@reporter)
  catch
    :exit, _ -> ""
  end

  @doc false
  def reporter_name, do: @reporter
end
