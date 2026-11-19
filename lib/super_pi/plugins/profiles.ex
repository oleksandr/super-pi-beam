defmodule SuperPi.Plugins.Profiles do
  @moduledoc "Persistent, composable personas bounded by the harness tool loadout and permission ceiling."
  use SuperPi.Extension

  @impl true
  def lifecycle_effects, do: []

  alias SuperPi.{Discovery, ExecutionMode}
  alias SuperPi.Durable.{Doc, Storage}
  alias SuperPi.Plugins.Permissions
  alias SuperPi.Plugins.Profiles.Definition
  alias SuperPi.UI.PermissionPrompt

  @selection_keys ~w(profile profilePolicy toolPolicy sessionMode executionMode dangerouslySkipPermissions workflowMode)

  def id, do: "profiles"
  def name, do: "Profiles"
  def description, do: "Persistent Ask, Plan, Build and discovered agent profiles"
  def supported?(agent), do: is_map(agent["profilesConfig"])

  @impl true
  def tools(_agent), do: [Map.put(spec(), "administrative", true)]

  @impl true
  def commands, do: ~w(mode workflow plan)

  @impl true
  def session_modes(agent, _ctx) do
    if supported?(agent) do
      %{
        "currentModeId" => agent["profile"],
        "availableModes" =>
          Enum.map(available(refresh(agent)), fn profile ->
            Map.take(profile, ["id", "name", "description"])
            |> Map.put("executionMode", profile["execution_mode"])
          end)
      }
    end
  end

  @impl true
  def select_mode(agent, id, _ctx), do: select(refresh(agent), id)

  @impl true
  def mode_state(agent, _ctx) do
    if not is_map(agent["profilePolicy"]) and agent["workflowMode"],
      do: %{
        "profile" => agent["workflowMode"],
        "profilePolicy" => nil,
        "toolPolicy" => nil,
        "workflowMode" => agent["workflowMode"]
      },
      else: changes(agent)
  end

  @impl true
  def configure_agent(agent, ctx) do
    opts = ctx.config

    legacy_mode =
      if is_binary(agent["harness"]) and not supported?(agent), do: agent["executionMode"]

    config =
      agent["profilesConfig"] ||
        %{
          "profiles" => normalize_profiles!(Keyword.fetch!(opts, :profiles)),
          "default" => if(opts[:default], do: to_string(opts[:default])),
          "discover" => opts[:discover] != false
        }

    agent = agent |> Map.put("profilesConfig", config) |> refresh()
    # Retain the active definition, even if an on-disk file changes its permissions.
    if is_map(agent["profilePolicy"]) and is_binary(agent["profile"]) do
      agent |> apply_policy(agent["profilePolicy"]) |> ExecutionMode.enforce_policy()
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
                "executionMode" => "plan",
                "toolPolicy" => %{
                  "executionMode" => "plan",
                  "tools" => %{"only" => []},
                  "restrictToLoadout" => true
                }
              })
          end
      end
    end
  end

  defp normalize_profiles!(profiles) when is_list(profiles) do
    Enum.map(profiles, fn profile ->
      Definition.normalize(profile) ||
        raise(
          ArgumentError,
          "Profiles requires explicit, valid profile maps; got #{inspect(profile)}"
        )
    end)
  end

  defp normalize_profiles!(_),
    do: raise(ArgumentError, "Profiles requires a list of profile maps")

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
    profiles = agent["profiles"] || []

    profile =
      Enum.find(profiles, &(&1["id"] == requested)) ||
        (ExecutionMode.normalize(requested) &&
           Enum.find(profiles, &(&1["execution_mode"] == requested))) || legacy_profile(requested)

    mode = if profile, do: profile["id"], else: requested

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
           "dangerouslySkipPermissions" => false,
           "sessionMode" => mode
         })
         |> apply_policy(profile)}
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

  defp apply_policy(agent, profile) do
    Map.put(agent, "toolPolicy", %{
      "executionMode" => profile["execution_mode"],
      "tools" => profile["tools"],
      "restrictToLoadout" => true
    })
    |> Map.put("sessionMode", profile["id"])
  end

  def changes(agent), do: Map.take(agent, @selection_keys)

  @impl true
  def prepare_request(agent, _ctx) do
    profile = agent["profilePolicy"] || %{}

    sections = Enum.reject(agent["systemSections"] || [], &(&1["id"] in ["profile", "workflow"]))

    request =
      agent
      |> Map.put("tools", offered_tools(agent["tools"] || [], agent))
      |> Map.put(
        "systemSections",
        sections ++ [%{"id" => "profile", "content" => profile["prompt"] || ""}]
      )

    request =
      Enum.reduce(["model", "effort"], request, fn key, acc ->
        if profile[key], do: Map.put(acc, key, profile[key]), else: acc
      end)

    {:ok, request}
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

  def offered_tools(tools, agent), do: Permissions.offered_tools(tools, agent)

  @impl true
  def on_input(input, ctx) do
    agent = Doc.snapshot("conversation", ctx.conversation_id, "pi.agent") || %{}

    trimmed = String.trim(input)

    if agent["disableSlashCommands"] do
      :continue
    else
      case String.split(trimmed, ~r/\s+/, parts: 2) do
        ["/plan" | rest] ->
          with {:ok, updated} <- select(refresh(agent), "plan") do
            Storage.configure_agent!(ctx.conversation_id, changes(updated))

            case rest do
              [task] when task != "" -> {:transform, task, []}
              _ -> :handled
            end
          end

        [command, id] when command in ["/mode", "/workflow"] ->
          with {:ok, updated} <- select(refresh(agent), id) do
            Storage.configure_agent!(ctx.conversation_id, changes(updated))
            :handled
          end

        [command] when command in ["/mode", "/workflow"] ->
          {:error, "Supply a mode id."}

        _ ->
          :continue
      end
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
  def execute_tool("switch_mode", args, ctx) do
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

  def execute_tool(_, _, _), do: :unhandled

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
