defmodule SuperPi.Plugins.Profiles do
  @moduledoc "Persistent, composable personas bounded by the harness tool loadout and permission ceiling."
  use SuperPi.Extension

  alias SuperPi.{Discovery, ExecutionMode, Tools}
  alias SuperPi.Durable.{Doc, Storage}
  alias SuperPi.Plugins.Permissions
  alias SuperPi.Plugins.Profiles.Definition
  alias SuperPi.UI.PermissionPrompt

  @administrative ~w(switch_mode request_command_approval request_workspace_access)
  @selection_keys ~w(profile profilePolicy executionMode maxExecutionMode dangerouslySkipPermissions workflowMode)

  def id, do: "profiles"
  def name, do: "Profiles"
  def description, do: "Persistent Ask, Plan, Build and discovered agent profiles"
  def supported?(agent), do: is_map(agent["profilesConfig"])

  @impl true
  def agent_start_phase, do: :request

  @impl true
  def configure_agent(agent, ctx) do
    opts = ctx.config

    legacy_mode =
      if is_binary(agent["harness"]) and not supported?(agent), do: agent["executionMode"]

    config =
      agent["profilesConfig"] ||
        %{
          "profiles" =>
            Enum.map(opts[:profiles] || [:ask, :plan, :build], &Definition.normalize/1)
            |> Enum.reject(&is_nil/1),
          "default" => to_string(opts[:default] || :ask),
          "discover" => opts[:discover] != false
        }

    agent = agent |> Map.put("profilesConfig", config) |> refresh()
    tools = Enum.reject(agent["tools"] || [], &(&1["name"] == "switch_mode")) ++ [spec()]
    agent = Map.put(agent, "tools", tools)
    # Retain the active definition, even if an on-disk file changes its permissions.
    if is_map(agent["profilePolicy"]) and is_binary(agent["profile"]) do
      ExecutionMode.enforce_workflow(agent)
    else
      explicit = get_in(ctx, [:initial_options, :mode])

      legacy =
        if legacy_mode &&
             ExecutionMode.rank_of(legacy_mode) >
               ExecutionMode.rank_of(agent["maxExecutionMode"] || "auto"),
           do: agent["maxExecutionMode"],
           else: legacy_mode

      chosen =
        agent["profile"] || agent["workflowMode"] || explicit || legacy || config["default"]

      case select(agent, chosen) do
        {:ok, updated} ->
          updated

        {:error, _} ->
          case available(agent) do
            [first | _] ->
              select(agent, first["id"]) |> elem(1)

            [] ->
              Map.merge(agent, %{
                "profile" => nil,
                "profilePolicy" => nil,
                "workflowMode" => nil,
                "executionMode" => "plan"
              })
          end
      end
    end
  end

  def refresh(agent) do
    if supported?(agent) do
      config = agent["profilesConfig"]

      discovered =
        if config["discover"],
          do: Discovery.discover_agents(agent["workspacePaths"] || []),
          else: []

      Map.put(agent, "profiles", Enum.uniq_by(config["profiles"] ++ discovered, & &1["id"]))
    else
      agent
    end
  end

  def available(agent) do
    ceiling = ExecutionMode.rank_of(agent["maxExecutionMode"] || "auto")
    profiles = agent["profiles"] || []

    profiles =
      if agent["profilePolicy"] && not Enum.any?(profiles, &(&1["id"] == agent["profile"])),
        do: profiles ++ [agent["profilePolicy"]],
        else: profiles

    Enum.filter(profiles, &(ExecutionMode.rank_of(&1["execution_mode"]) <= ceiling))
  end

  def select(agent, requested) do
    mode =
      if requested == "accept-edits" and
           Enum.any?(agent["profiles"] || [], &(&1["id"] == "build")),
         do: "build",
         else: requested

    profile = Enum.find(agent["profiles"] || [], &(&1["id"] == mode)) || legacy_profile(mode)

    cond do
      not supported?(agent) ->
        {:error, "This harness does not include Profiles."}

      is_nil(profile) ->
        {:error, "Unknown profile #{inspect(requested)}."}

      ExecutionMode.rank_of(profile["execution_mode"]) >
          ExecutionMode.rank_of(agent["maxExecutionMode"] || "auto") ->
        {:error, "Profile #{mode} exceeds this harness's permission ceiling."}

      true ->
        {:ok,
         Map.merge(agent, %{
           "profile" => mode,
           "profilePolicy" => profile,
           "executionMode" => profile["execution_mode"],
           "workflowMode" => nil,
           "dangerouslySkipPermissions" => false
         })}
    end
  end

  defp legacy_profile(mode) when mode in ["auto", "accept-edits", "plan"] do
    Definition.normalize(%{
      id: mode,
      name: %{"auto" => "Auto", "accept-edits" => "Accept edits", "plan" => "Plan"}[mode],
      description: "Legacy permission mode within the harness ceiling.",
      execution_mode: mode,
      tools: :all
    })
  end

  defp legacy_profile(_), do: nil

  def for_acp(agent) do
    ceiling = agent["maxExecutionMode"] || "auto"
    remote = Permissions.remote_mode("auto")

    ceiling =
      if ExecutionMode.rank_of(remote) < ExecutionMode.rank_of(ceiling), do: remote, else: ceiling

    agent = agent |> Map.put("maxExecutionMode", ceiling) |> refresh()

    if (supported?(agent) and agent["profilePolicy"]) &&
         ExecutionMode.rank_of(agent["profilePolicy"]["execution_mode"]) >
           ExecutionMode.rank_of(ceiling) do
      case Enum.sort_by(available(agent), &ExecutionMode.rank_of(&1["execution_mode"]), :desc) do
        [first | _] -> select(agent, first["id"]) |> elem(1)
        [] -> ExecutionMode.clamp(agent)
      end
    else
      ExecutionMode.clamp(agent)
    end
  end

  def changes(agent), do: Map.take(agent, @selection_keys)

  @impl true
  def before_agent_start(agent, _ctx) do
    profile = agent["profilePolicy"] || %{}

    removed =
      if agent["executionMode"] == "plan",
        do: ["profile", "workflow", "session_start_hooks", "agy_session_start_hooks"],
        else: ["profile", "workflow"]

    sections =
      Enum.reject(
        agent["systemSections"] || [],
        &(&1["id"] in removed)
      )

    context =
      "\nWorkspace roots (JSON): #{Jason.encode!(agent["workspacePaths"] || [])}. Relative paths use the first root. " <>
        "Use git_inspect for read-only Git queries. For user requests to approve commands or folders, use request_command_approval or request_workspace_access when available. Chat text alone does not change approvals."

    request =
      agent
      |> Map.put("tools", offered_tools(agent["tools"] || [], agent))
      |> Map.put(
        "systemSections",
        sections ++ [%{"id" => "profile", "content" => (profile["prompt"] || "") <> context}]
      )

    request =
      Enum.reduce(["model", "effort"], request, fn key, acc ->
        if profile[key], do: Map.put(acc, key, profile[key]), else: acc
      end)

    {:request, request}
  end

  @impl true
  def before_provider_request(payload, ctx) do
    agent = Doc.snapshot("conversation", ctx.conversation_id, "pi.agent") || %{}
    profile = agent["profilePolicy"] || %{}

    payload =
      Enum.reduce([{:model, "model"}, {:effort, "effort"}], payload, fn {key, field}, acc ->
        if profile[field], do: Map.put(acc, key, profile[field]), else: acc
      end)

    {:ok, Map.update(payload, :tools, [], &offered_tools(&1, agent))}
  end

  def offered_tools(tools, agent),
    do: Enum.filter(tools, &(check_tool(&1["name"], agent) == :allow))

  def check_tool(name, agent) do
    policy = agent["profilePolicy"]

    cond do
      supported?(agent) and not is_map(policy) ->
        {:block, "No usable profile is configured for this harness."}

      not is_map(policy) ->
        :allow

      not Enum.any?(agent["tools"] || [], &(&1["name"] == name)) ->
        {:block, "Tool #{name} is outside this harness's loadout."}

      name in @administrative ->
        :allow

      not matches_filter?(name, policy["tools"]) ->
        {:block, "Tool #{name} is excluded by profile #{agent["profile"]}."}

      agent["executionMode"] == "plan" and not read_only?(name, agent) ->
        {:block, "Tool #{name} is blocked by the read-only profile."}

      true ->
        :allow
    end
  end

  defp matches_filter?(_name, "all"), do: true
  defp matches_filter?(name, %{"only" => names}), do: name in names
  defp matches_filter?(name, %{"except" => names}), do: name not in names
  defp matches_filter?(_, _), do: false

  defp read_only?(name, agent) do
    case Tools.effects(name, agent) do
      [_ | _] = effects -> Enum.all?(effects, &(&1 in ["read", "net_read"]))
      _ -> false
    end
  end

  @impl true
  def before_tool(name, _args, ctx) do
    check_tool(name, Doc.snapshot("conversation", ctx.conversation_id, "pi.agent") || %{})
  end

  @impl true
  def on_input(input, ctx) do
    agent = Doc.snapshot("conversation", ctx.conversation_id, "pi.agent") || %{}

    case {agent["disableSlashCommands"],
          Regex.run(~r/^\/(?:mode|workflow)\s+(\S+)\s*$/, String.trim(input))} do
      {disabled, [_, id]} when disabled != true ->
        with {:ok, updated} <- agent |> refresh() |> select(id) do
          Storage.configure_agent!(ctx.conversation_id, changes(updated))
          :handled
        end

      _ ->
        :continue
    end
  end

  def spec do
    %{
      "name" => "switch_mode",
      "effects" => ["state_write"],
      "description" =>
        "Request a profile switch in this conversation. Increasing permissions requires human approval. Include the proposed plan when leaving Plan for Build.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{"mode" => %{"type" => "string"}, "plan" => %{"type" => "string"}},
        "required" => ["mode"]
      }
    }
  end

  @impl true
  def wrap_tool("switch_mode", args, _next, ctx) do
    agent = Doc.snapshot("conversation", ctx.conversation_id, "pi.agent") || %{}
    settings = Permissions.load_effective_settings(agent)

    with true <-
           is_nil(args["plan"]) or (is_binary(args["plan"]) and byte_size(args["plan"]) <= 50_000),
         false <- "switch_mode" in (get_in(settings, ["permissions", "denyTools"]) || []),
         {:ok, target} <- agent |> refresh() |> select(args["mode"]),
         :ok <- approve_switch(agent, target, args, ctx, settings) do
      current = Doc.snapshot("conversation", ctx.conversation_id, "pi.agent") || %{}
      current_settings = Permissions.load_effective_settings(current)

      with true <- changes(current) == changes(agent),
           false <-
             "switch_mode" in (get_in(current_settings, ["permissions", "denyTools"]) || []),
           {:ok, checked} <- current |> refresh() |> select(args["mode"]),
           true <- checked["profilePolicy"] == target["profilePolicy"] do
        Storage.configure_agent!(ctx.conversation_id, changes(checked))
        %{"output" => "Switched to #{checked["profile"]}.", "details" => %{}}
      else
        _ -> error("Profile policy changed while awaiting approval; request the switch again.")
      end
    else
      {:error, reason} -> error(reason)
      _ -> error("Invalid switch request or switch_mode is disabled by policy.")
    end
  end

  def wrap_tool(_name, args, next, _ctx), do: next.(args)

  defp approve_switch(agent, target, args, ctx, settings) do
    if ExecutionMode.rank_of(target["executionMode"]) >
         ExecutionMode.rank_of(agent["executionMode"]) do
      fields = %{
        "tool_name" => "switch_mode",
        "arguments" => args,
        "risk" => "high",
        "reason" =>
          "Switch to #{target["profile"]} (#{target["executionMode"]})?\n\n#{args["plan"] || "No plan supplied."}",
        "options" => [
          %{"option_id" => "allow_once", "kind" => "allow_once", "name" => "Approve switch"},
          %{
            "option_id" => "reject_once",
            "kind" => "reject_once",
            "name" => "Stay in current mode"
          }
        ]
      }

      if PermissionPrompt.available?(ctx.conversation_id, settings) and
           PermissionPrompt.ask(ctx, fields) == :allow_once,
         do: :ok,
         else:
           {:error,
            "Switch rejected, cancelled or unavailable. The current profile is unchanged."}
    else
      :ok
    end
  end

  defp error(message), do: %{"is_error" => true, "output" => message, "details" => %{}}
end
