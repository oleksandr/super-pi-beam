defmodule SuperPi.Plugins.Scheduler do
  @moduledoc """
  Scheduled and webhook-triggered runs: the tools `schedule_create`, `schedule_list` and
  `schedule_cancel`.

  A schedule is a row in `schedules`, fired by one static `Oban.Plugins.Cron` entry (see
  `SuperPi.Schedule` for the exactly-once design, run modes, catch-up and failure handling).
  Granularity is one minute.

  ## Tools

  | Tool | Effects | Use |
  |---|---|---|
  | `schedule_create` | `state_write` | Create a cron schedule (or a webhook trigger when allowed). |
  | `schedule_list` | `read` | List the conversation's schedules. |
  | `schedule_cancel` | `state_write` | Cancel one. |

  The tools are not in the global tool catalog. `before_agent_start` appends their specs to the
  conversation's tool list and `wrap_tool` serves the calls, as `Todo` does, so a harness
  without this plugin never offers them.

  ## Config

  `{SuperPi.Plugins.Scheduler, opts}`:

  | Option | Default | Meaning |
  |---|---|---|
  | `:allow_webhooks` | `false` | Let `schedule_create` make `trigger: "webhook"` schedules. An endpoint that is outside the bearer token and spends money is opt-in. |
  | `:allow_nested` | `false` | Allow `schedule_create` inside a scheduled run (the loop guard). |
  | `:harness` | `"super-pi-librarian"` | Harness whose plugins a run uses. |
  | `:timezone` | `"Etc/UTC"` | Zone for a cron expression when the call gives none. |
  | `:max_per_conversation` | `10` | Schedules per conversation. |
  | `:min_interval_minutes` | `5` | Smallest gap between two fires. |

  ## Limits

  - Forks do not copy schedules. Rows belong to a conversation id, so forking a conversation
    ten times does not create ten daily briefings. A run of mode `"fork"` is itself a fork and
    has no schedules.
  - A scheduled run cannot create schedules (the loop guard) unless `:allow_nested` is set.
  - A webhook token appears once, in the result of `schedule_create`, and so in that
    conversation's transcript.
  """

  use SuperPi.Extension

  alias SuperPi.Durable.Doc
  alias SuperPi.Schedule

  @tools ["schedule_create", "schedule_list", "schedule_cancel"]
  @default_harness "super-pi-librarian"

  def id, do: "scheduler"
  def name, do: "Scheduler"
  def description, do: "Scheduled and webhook-triggered runs backed by Oban"

  @doc "The tool specs for the given options."
  def tool_specs(opts \\ []) do
    webhooks? = opt(opts, :allow_webhooks, false) == true

    trigger =
      if webhooks?,
        do: %{
          "trigger" => %{
            "type" => "string",
            "enum" => ["cron", "webhook"],
            "description" => "'cron' (default) fires on a schedule. 'webhook' fires when a third party POSTs to the returned URL; omit `cron`. The body is added to the prompt, or put {{payload}} in the prompt to place it."
          }
        },
        else: %{}

    [
      %{
        "name" => "schedule_create",
        "effects" => ["state_write"],
        "description" =>
          "Run a prompt later or repeatedly, with nobody watching. `cron` is a five-field expression (minute hour day-of-month month day-of-week) or @daily, @hourly, @weekly. " <>
            "Fires are at least #{opt(opts, :min_interval_minutes, 5)} minutes apart. Each run is a separate unattended turn, so write a prompt that stands alone. " <>
            "Modes: 'fork' (default) runs on a branch of this conversation and keeps this transcript clean, 'append' adds the turn here, 'fresh' starts an empty conversation (cheapest). " <>
            "A run that fails three times in a row pauses the schedule. A scheduled run cannot create schedules.",
        "parameters" => %{
          "type" => "object",
          "properties" =>
            Map.merge(
              %{
                "prompt" => %{"type" => "string", "description" => "What to do on each run."},
                "cron" => %{"type" => "string", "description" => "Cron expression, for example '0 7 * * 1-5' (weekdays at 07:00)."},
                "timezone" => %{"type" => "string", "description" => "IANA zone for `cron`, for example 'Europe/London'. Default #{opt(opts, :timezone, "Etc/UTC")}."},
                "mode" => %{"type" => "string", "enum" => SuperPi.Durable.Schemas.Schedule.modes(), "description" => "Where a run happens. Default 'fork'."},
                "catch_up" => %{"type" => "boolean", "description" => "Run once after downtime for fires that were missed. Default false: a late run is skipped or cancelled, not delivered stale."},
                "name" => %{"type" => "string", "description" => "Short label."}
              },
              trigger
            ),
          "required" => ["prompt"]
        }
      },
      %{
        "name" => "schedule_list",
        "effects" => ["read"],
        "description" => "List the schedules of this conversation with status, next fire and failures.",
        "parameters" => %{"type" => "object", "properties" => %{}}
      },
      %{
        "name" => "schedule_cancel",
        "effects" => ["state_write"],
        "description" => "Cancel a schedule of this conversation by id. A run that already started finishes.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{"id" => %{"type" => "integer", "description" => "Schedule id from schedule_list."}},
          "required" => ["id"]
        }
      }
    ]
  end

  @impl true
  def before_agent_start(agent_cfg, ctx) do
    existing = Map.get(agent_cfg, "tools") || Map.get(agent_cfg, :tools) || []
    have = MapSet.new(existing, & &1["name"])
    missing = Enum.reject(tool_specs(config(ctx)), &MapSet.member?(have, &1["name"]))
    {:ok, Map.put(agent_cfg, "tools", existing ++ missing)}
  end

  @impl true
  def wrap_tool("schedule_create", args, _next, ctx), do: create(args, ctx)
  def wrap_tool("schedule_list", _args, _next, ctx), do: list(ctx)
  def wrap_tool("schedule_cancel", args, _next, ctx), do: cancel(args, ctx)
  def wrap_tool(_name, args, next, _ctx), do: next.(args)

  # --- Tools ---

  defp create(args, ctx) do
    conv_id = Map.get(ctx, :conversation_id)
    cfg = config(ctx)
    trigger = arg(args, "trigger") || "cron"

    cond do
      is_nil(conv_id) ->
        error("no conversation")

      Schedule.scheduled_run?(Map.get(ctx, :active_task_id)) and opt(cfg, :allow_nested, false) != true ->
        error("schedule_create is blocked inside a scheduled run. A run that schedules runs multiplies without anyone to stop it.")

      trigger == "webhook" and opt(cfg, :allow_webhooks, false) != true ->
        error("webhook triggers are not enabled for this harness")

      true ->
        attrs = %{
          conversation_id: conv_id,
          kind: trigger,
          prompt: arg(args, "prompt"),
          cron: arg(args, "cron"),
          timezone: arg(args, "timezone") || opt(cfg, :timezone, "Etc/UTC"),
          mode: arg(args, "mode") || "fork",
          catch_up: arg(args, "catch_up") == true,
          name: arg(args, "name"),
          harness: opt(cfg, :harness, @default_harness),
          agent: Doc.snapshot("conversation", conv_id, "pi.agent") || %{}
        }

        opts = [
          max_per_conversation: opt(cfg, :max_per_conversation, 10),
          min_interval_minutes: opt(cfg, :min_interval_minutes, 5)
        ]

        case Schedule.create(attrs, opts) do
          {:ok, schedule, token} -> created(schedule, token)
          {:error, reason} -> error(reason)
        end
    end
  end

  defp created(schedule, nil) do
    %{
      "output" => "Created schedule ##{schedule.id}. Next run: #{iso(schedule.next_fire_at)} (#{schedule.timezone}, mode #{schedule.mode}).",
      "structured_output" => summary(schedule),
      "details" => %{"action" => "create", "id" => schedule.id}
    }
  end

  defp created(schedule, token) do
    path = "/v1/triggers/" <> token

    %{
      "output" =>
        "Created webhook trigger ##{schedule.id}. Give the sender: POST #{path} (add an Idempotency-Key header to make retries safe). " <>
          "This secret is shown once.",
      "structured_output" => Map.put(summary(schedule), "path", path),
      "details" => %{"action" => "create", "id" => schedule.id}
    }
  end

  defp list(ctx) do
    case Map.get(ctx, :conversation_id) do
      nil ->
        error("no conversation")

      conv_id ->
        schedules = Schedule.list(conv_id)

        text =
          case schedules do
            [] -> "No schedules."
            _ -> Enum.map_join(schedules, "\n", &line/1)
          end

        %{
          "output" => text,
          "structured_output" => %{"schedules" => Enum.map(schedules, &summary/1)},
          "details" => %{"action" => "list", "count" => length(schedules)}
        }
    end
  end

  defp cancel(args, ctx) do
    conv_id = Map.get(ctx, :conversation_id)

    with true <- is_integer(conv_id) or {:error, "no conversation"},
         id when is_integer(id) <- to_int(arg(args, "id")) || {:error, "id must be an integer"},
         :ok <- Schedule.cancel(conv_id, id) |> not_found() do
      %{"output" => "Cancelled schedule ##{id}.", "structured_output" => %{"id" => id, "status" => "cancelled"}, "details" => %{"action" => "cancel", "id" => id}}
    else
      {:error, reason} -> error(reason)
    end
  end

  defp not_found(:ok), do: :ok
  defp not_found({:error, :not_found}), do: {:error, "no such schedule in this conversation"}

  defp line(s) do
    what = if s.kind == "webhook", do: "webhook", else: "#{s.cron} (#{s.timezone})"
    next = if s.kind == "cron", do: ", next #{iso(s.next_fire_at)}", else: ""
    warn = if s.consecutive_failures > 0, do: ", #{s.consecutive_failures} failed in a row", else: ""
    label = if s.name, do: " #{s.name}:", else: ""
    "##{s.id}#{label} #{what}, #{s.mode}, #{s.status}#{next}#{warn}"
  end

  defp summary(s) do
    %{
      "id" => s.id,
      "name" => s.name,
      "kind" => s.kind,
      "cron" => s.cron,
      "timezone" => s.timezone,
      "mode" => s.mode,
      "status" => s.status,
      "catch_up" => s.catch_up,
      "next_fire_at" => iso(s.next_fire_at),
      "last_fire_at" => iso(s.last_fire_at),
      "consecutive_failures" => s.consecutive_failures,
      "last_error" => s.last_error
    }
  end

  defp error(message) do
    %{"output" => message, "structured_output" => %{"error" => message}, "details" => %{}, "is_error" => true}
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp to_int(n) when is_integer(n), do: n

  defp to_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp to_int(_), do: nil

  defp arg(args, key) when is_map(args), do: Map.get(args, key)
  defp arg(_, _), do: nil

  defp config(ctx), do: Map.get(ctx, :config) || []

  defp opt(cfg, key, default) when is_list(cfg), do: Keyword.get(cfg, key, default)
  defp opt(cfg, key, default) when is_map(cfg), do: Map.get(cfg, key, default)
  defp opt(_, _, default), do: default

  @doc false
  def tool_names, do: @tools
end
