defmodule SuperPi.Plugins.JevRouter do
  @moduledoc """
  Jev Router Plugin (migrated from Pi ecosystem `jev-router.ts`).

  Dynamic model cascading and phase-based routing:
  - Planning Phase: Routes to a high-reasoning frontier model (`planning_model`, e.g. `gemini-2.5-pro`)
    while the agent is exploring, inspecting, and formulating architectural plans.
  - Implementation Phase: Once the first `write` or `edit` tool is executed, automatically cascades
    the session to a fast, cost-effective model (`implementation_model`, e.g. `gemini-2.5-flash`).

  Reduces end-to-end token expenditure by 60–80% without sacrificing planning depth.
  """

  use SuperPi.Extension
  require Logger

  @default_planning_model "gemini-2.5-pro"
  @default_implementation_model "gemini-2.5-flash"
  @edit_tools ["write", "edit"]

  def id, do: "jev_router"
  def name, do: "Jev Dynamic Model Router"
  def description, do: "Cascades from deep planning model to fast implementation model on first edit"

  @impl true
  def before_request(derived_context, ctx) do
    opts = Map.get(ctx, :jev_opts, [])
    planning_model = Keyword.get(opts, :planning_model, @default_planning_model)
    implementation_model = Keyword.get(opts, :implementation_model, @default_implementation_model)

    messages = Map.get(derived_context, :messages, [])
    phase = determine_phase(messages)

    effective_model =
      case phase do
        :planning -> planning_model
        :implementation -> implementation_model
      end

    Logger.debug("[JevRouter] Phase: #{phase} => Selected model: #{effective_model}")

    # Update model in derived context
    updated_context =
      derived_context
      |> Map.put(:model, effective_model)
      |> Map.put(:jev_phase, phase)

    {:ok, updated_context}
  end

  @doc """
  Determines the current work phase (:planning or :implementation) by inspecting
  whether any edit tools ('write' or 'edit') have been called in previous turns.
  """
  def determine_phase(messages) when is_list(messages) do
    has_edit_call? =
      Enum.any?(messages, fn msg ->
        case msg do
          %{"role" => "assistant", "content" => blocks} when is_list(blocks) ->
            Enum.any?(blocks, fn
              %{"type" => "tool_call", "name" => name} -> name in @edit_tools
              _ -> false
            end)

          %{"role" => "tool", "name" => name} ->
            name in @edit_tools

          _ ->
            false
        end
      end)

    if has_edit_call?, do: :implementation, else: :planning
  end

  def determine_phase(_), do: :planning
end
