defmodule SuperPi.Plugins.Todo do
  @moduledoc """
  Todo Task Ledger Plugin (migrated from Pi ecosystem `todo.ts`).

  Registers the `todo` tool (`add`, `toggle`, `list`, `clear`) allowing agents to maintain
  a structured checklist across multi-turn sessions. State is stored directly inside
  the conversation's durable `pi.live` document, ensuring that forks and branch rollbacks
  restore the exact matching task state.
  """

  use SuperPi.Extension
  alias SuperPi.Durable.{Doc, Storage}

  def id, do: "todo"
  def name, do: "Todo Task Ledger"
  def description, do: "Stateful task management tool stored in durable session documents"

  @tool_spec %{
    "name" => "todo",
    "description" =>
      "Manage a structured task checklist. Actions: 'list' (view all), 'add' (create new item), 'toggle' (toggle completed status by id), 'clear' (remove completed items).",
    "parameters" => %{
      "type" => "object",
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => ["list", "add", "toggle", "clear"],
          "description" => "Checklist operation to execute"
        },
        "text" => %{"type" => "string", "description" => "Description of task to add (required for 'add')"},
        "id" => %{"type" => "integer", "description" => "Unique item numeric ID (required for 'toggle')"}
      },
      "required" => ["action"]
    }
  }

  @impl true
  def before_agent_start(agent_cfg, _ctx) do
    existing_tools = Map.get(agent_cfg, "tools", [])

    updated_tools =
      if Enum.any?(existing_tools, &(&1["name"] == "todo")) do
        existing_tools
      else
        existing_tools ++ [@tool_spec]
      end

    {:ok, Map.put(agent_cfg, "tools", updated_tools)}
  end

  @impl true
  def wrap_tool("todo", args, _next, ctx) do
    args = if is_map(args), do: args, else: %{}
    conv_id = Map.get(ctx, :conversation_id)
    action = to_string(Map.get(args, "action") || Map.get(args, :action) || "list")
    text = Map.get(args, "text") || Map.get(args, :text)
    item_id = Map.get(args, "id") || Map.get(args, :id)

    todos = get_todos(conv_id)

    case action do
      "add" when is_binary(text) and byte_size(text) > 0 ->
        next_id = (Enum.map(todos, & &1["id"]) |> Enum.max(fn -> 0 end)) + 1
        new_item = %{"id" => next_id, "text" => text, "done" => false}
        list = todos ++ [new_item]
        save_todos(conv_id, list)

        %{
          "output" => "Added todo ##{next_id}: #{text}",
          "structured_output" => %{"todos" => list, "action" => action},
          "details" => %{"action" => action, "count" => length(list)}
        }

      "toggle" ->
        case Enum.find(todos, &(&1["id"] == item_id)) do
          nil ->
            %{
              "output" => "Todo item ##{item_id} not found",
              "structured_output" => %{"todos" => todos, "action" => action},
              "details" => %{"action" => action, "count" => length(todos)},
              "is_error" => true
            }

          item ->
            list =
              Enum.map(todos, fn i ->
                if i["id"] == item_id, do: Map.update(i, "done", true, &(not &1)), else: i
              end)

            new_done = not Map.get(item, "done", false)
            status = if new_done, do: "completed", else: "pending"
            save_todos(conv_id, list)

            %{
              "output" => "Toggled todo ##{item_id} to #{status}",
              "structured_output" => %{"todos" => list, "action" => action},
              "details" => %{"action" => action, "count" => length(list)}
            }
        end

      "clear" ->
        list = Enum.filter(todos, &(&1["done"] == false))
        save_todos(conv_id, list)

        %{
          "output" => "Cleared completed todos (remaining: #{length(list)})",
          "structured_output" => %{"todos" => list, "action" => action},
          "details" => %{"action" => action, "count" => length(list)}
        }

      _ ->
        %{
          "output" => "Current checklist:\n" <> render_checklist(todos),
          "structured_output" => %{"todos" => todos, "action" => action},
          "details" => %{"action" => action, "count" => length(todos)}
        }
    end
  end

  def wrap_tool(_name, args, next, _ctx) do
    next.(args)
  end

  defp get_todos(nil), do: []

  defp get_todos(conv_id) do
    doc = Doc.snapshot("conversation", conv_id, "pi.live") || %{}
    Map.get(doc, "todos", [])
  end

  defp save_todos(nil, _todos), do: :ok

  defp save_todos(conv_id, todos) do
    Storage.commit(fn seq ->
      doc = Doc.snapshot("conversation", conv_id, "pi.live") || %{}
      updated = Map.put(doc, "todos", todos)
      Doc.put_doc("conversation", conv_id, "pi.live", updated, seq)
    end)
  rescue
    _ -> :ok
  end

  defp render_checklist([]), do: "  (no todos in ledger)"

  defp render_checklist(todos) do
    Enum.map_join(todos, "\n", fn item ->
      mark = if item["done"], do: "[x]", else: "[ ]"
      "  #{mark} ##{item["id"]}: #{item["text"]}"
    end)
  end

  @doc """
  Returns the tool specification map for direct registration.
  """
  def tool_spec, do: @tool_spec
end
