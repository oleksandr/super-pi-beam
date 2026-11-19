defmodule SuperPi.SessionModes do
  @moduledoc "Client-independent session modes supplied by extensions, with a legacy permission-mode fallback."
  alias SuperPi.ExecutionMode

  @legacy [
    %{
      "id" => "plan",
      "name" => "Plan",
      "description" => "Read-only inspection and planning.",
      "executionMode" => "plan"
    },
    %{
      "id" => "accept-edits",
      "name" => "Accept edits",
      "description" => "Edit files; other tools ask first.",
      "executionMode" => "accept-edits"
    },
    %{
      "id" => "auto",
      "name" => "Auto",
      "description" => "Automatic permissions within the harness ceiling.",
      "executionMode" => "auto"
    }
  ]

  def list(agent) do
    modes =
      case provider(agent) do
        nil -> %{"currentModeId" => agent["executionMode"], "availableModes" => @legacy}
        mod -> mod.session_modes(agent, %{})
      end

    ceiling = ExecutionMode.rank_of(agent["maxExecutionMode"] || "auto")

    Map.update!(
      modes,
      "availableModes",
      &Enum.filter(&1, fn mode -> ExecutionMode.rank_of(mode["executionMode"]) <= ceiling end)
    )
  end

  def select(agent, id) do
    result =
      case provider(agent) do
        nil ->
          if Enum.any?(list(agent)["availableModes"], &(&1["id"] == id)),
            do:
              {:ok,
               Map.merge(agent, %{"executionMode" => id, "dangerouslySkipPermissions" => false})},
            else: {:error, "Mode #{inspect(id)} is not available for this harness."}

        mod ->
          mod.select_mode(agent, id, %{})
      end

    with {:ok, updated} <- result do
      if ExecutionMode.rank_of(updated["executionMode"]) >
           ExecutionMode.rank_of(agent["maxExecutionMode"] || "auto"),
         do: {:error, "Mode exceeds the harness permission ceiling."},
         else: {:ok, Map.put(updated, "maxExecutionMode", agent["maxExecutionMode"])}
    end
  end

  def state(agent) do
    case provider(agent) do
      nil -> Map.take(agent, ["executionMode"])
      mod -> mod.mode_state(agent, %{})
    end
  end

  def restore(agent, previous) do
    case provider(agent) do
      nil ->
        agent |> Map.merge(state(previous)) |> ExecutionMode.enforce_policy()

      mod ->
        agent
        |> Map.merge(mod.mode_state(previous, %{}))
        |> mod.configure_agent(%{config: []})
        |> ExecutionMode.enforce_policy()
    end
  end

  def with_ceiling(agent, ceiling) do
    max_mode = agent["maxExecutionMode"] || "auto"

    max_mode =
      if ExecutionMode.rank_of(ceiling) < ExecutionMode.rank_of(max_mode),
        do: ceiling,
        else: max_mode

    agent = Map.put(agent, "maxExecutionMode", max_mode)
    modes = list(agent)

    if Enum.any?(modes["availableModes"], &(&1["id"] == modes["currentModeId"])) do
      ExecutionMode.enforce_policy(agent)
    else
      case Enum.sort_by(
             modes["availableModes"],
             &ExecutionMode.rank_of(&1["executionMode"]),
             :desc
           ) do
        [first | _] -> select(agent, first["id"]) |> elem(1)
        [] -> ExecutionMode.enforce_policy(agent)
      end
    end
  end

  def custom?(agent), do: provider(agent) != nil

  defp provider(agent) do
    case agent["modeProviders"] || [] do
      [] ->
        nil

      [name] ->
        mod = existing_module(name)

        if mod && Code.ensure_loaded?(mod) && function_exported?(mod, :session_modes, 2) &&
             is_map(mod.session_modes(agent, %{})),
           do: mod

      _ ->
        raise ArgumentError, "A harness must compose only one session-mode provider"
    end
  end

  defp existing_module(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end
end
