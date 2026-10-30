defmodule SuperPi.Plugins.Handoff do
  @moduledoc """
  Handoff & Context Distillation Plugin (migrated from Pi ecosystem `handoff.ts`).

  Provides the `handoff` tool. It stores a child conversation that starts with the summary
  and goal that the model supplies, and then ends the current turn. It does not run the
  child conversation, and it does not summarize the parent itself.
  """

  use SuperPi.Extension
  alias SuperPi.Durable.Storage
  require Logger

  def id, do: "handoff"
  def name, do: "Handoff & Session Distillation"
  def description, do: "Stores a child conversation seeded with a model-supplied summary and goal"

  @tool_spec %{
    "name" => "handoff",
    "description" =>
      "Transfer context to a new focused conversation session. Distills key decisions and files into a fresh starting prompt, eliminating accumulated token bloat.",
    "parameters" => %{
      "type" => "object",
      "properties" => %{
        "goal" => %{"type" => "string", "description" => "Clear objective of the new thread"},
        "summary" => %{"type" => "string", "description" => "Synthesized background and decisions made so far"},
        "files" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "List of relevant files to carry forward"
        }
      },
      "required" => ["goal", "summary"]
    }
  }

  @impl true
  def before_agent_start(agent_cfg, _ctx) do
    existing_tools = Map.get(agent_cfg, "tools") || Map.get(agent_cfg, :tools) || []

    updated_tools =
      if Enum.any?(existing_tools, &(&1["name"] == "handoff")) do
        existing_tools
      else
        existing_tools ++ [@tool_spec]
      end

    {:ok, Map.put(agent_cfg, "tools", updated_tools)}
  end

  @impl true
  def wrap_tool("handoff", args, _next, ctx) do
    args = if is_map(args), do: args, else: %{}
    goal = Map.get(args, "goal") || Map.get(args, :goal) || ""
    summary = Map.get(args, "summary") || Map.get(args, :summary) || ""

    files =
      case Map.get(args, "files") || Map.get(args, :files) do
        list when is_list(list) -> list
        str when is_binary(str) -> [str]
        _ -> []
      end

    parent_conv_id = Map.get(ctx, :conversation_id)

    files_bullet =
      if files != [] do
        "\nFiles involved:\n" <> Enum.map_join(files, "\n", &"- #{&1}")
      else
        ""
      end

    distilled_prompt = """
    ## Context Transfer
    #{summary}#{files_bullet}

    ## Task Goal
    #{goal}
    """ |> String.trim()

    parent_agent =
      if parent_conv_id do
        SuperPi.Durable.Doc.snapshot("conversation", parent_conv_id, "pi.agent") || %{}
      else
        %{}
      end

    parent_model = Map.get(parent_agent, "model") || Map.get(parent_agent, :model)

    # The child never has more permission than the parent: it copies the mode, workspace and
    # permission settings. Without them the child would run in `auto` mode in the server's cwd.
    child_agent =
      %{
        "systemSections" => [
          %{"id" => "handoff_context", "content" => "You are working on a focused thread handed off from session #{parent_conv_id}."}
        ],
        "tools" => SuperPi.Tools.active_llm_tools(),
        "executionMode" => Map.get(parent_agent, "executionMode", "accept-edits"),
        "dangerouslySkipPermissions" => Map.get(parent_agent, "dangerouslySkipPermissions") == true
      }
      |> Map.merge(Map.take(parent_agent, ["workspacePaths", "globalConfigDir", "appDataDir", "settingsOverride", "effort"]))
      |> then(fn a ->
        if parent_model, do: Map.put(a, "model", parent_model), else: a
      end)

    # Create new clean child conversation in durable storage
    child_conv =
      Storage.create_conversation!(
        parent_conversation_id: parent_conv_id,
        agent: child_agent,
        owner: if(parent_conv_id, do: SuperPi.Auth.owner(parent_conv_id))
      )

    Storage.append_entry!(child_conv.id, "pi.message", %{
      "role" => "user",
      "content" => [%{"type" => "text", "text" => distilled_prompt}]
    })

    Logger.info("[Handoff] Created child session #{child_conv.id} from parent #{parent_conv_id}")

    %{
      "output" => "Handoff completed. Created child session #{child_conv.id} with distilled context.\nPrompt:\n#{distilled_prompt}",
      "structured_output" => %{
        "child_conversation_id" => child_conv.id,
        "parent_conversation_id" => parent_conv_id,
        "distilled_prompt" => distilled_prompt
      },
      "details" => %{"child_id" => child_conv.id},
      "control" => %{"terminate" => true}
    }
  end

  def wrap_tool(_name, args, next, _ctx) do
    next.(args)
  end

  @doc """
  Returns the tool specification map for direct registration.
  """
  def tool_spec, do: @tool_spec
end
