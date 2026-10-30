defmodule SuperPi.Plugins.JevRouter do
  @moduledoc """
  Jev Router Plugin (migrated from Pi ecosystem `jev-router.ts`).

  Dynamic model cascading and phase-based routing:
  - Planning Phase: Routes to a high-reasoning frontier model (`planning_model`, e.g. `gemini-3.1-pro-preview`)
    while the agent is exploring, inspecting, and formulating architectural plans.
  - Implementation Phase: Once the first `write` or `edit` tool is executed, automatically cascades
    the session to a fast, cost-effective model (`implementation_model`, e.g. `gemini-3-flash-preview`).

  Reduces end-to-end token expenditure by 60–80% without sacrificing planning depth.

  ### Configuration Options (`ctx[:config]` or harness tuple):
  - `:planning_model` - Model identifier for planning phase.
  - `:implementation_model` - Model identifier for implementation phase.
  - `:edit_tools` - List of tool names that trigger transition to implementation phase (default: `["write", "edit"]`).
  - Environment variables: `JEV_PLANNING_MODEL`, `JEV_IMPLEMENTATION_MODEL`.
  """

  use SuperPi.Extension
  require Logger

  @default_planning_model "gemini-3.1-pro-preview"
  @default_implementation_model "gemini-3-flash-preview"
  @default_edit_tools ["write", "edit", "write_file", "edit_file"]

  def id, do: "jev_router"
  def name, do: "Jev Dynamic Model Router"

  def description,
    do: "Cascades from deep planning model to fast implementation model on first edit"

  @impl true
  def before_request(derived_context, ctx) do
    config = Map.get(ctx, :config, [])
    fallback_opts = Map.get(ctx, :jev_opts, [])
    merged_opts = Keyword.merge(fallback_opts, config)

    # The built-in default models are Gemini models: only apply them when Gemini is
    # usable. Explicitly supplied models (options or env) are always honoured.
    explicit_models? =
      Enum.any?(
        [
          Keyword.get(merged_opts, :planning_model),
          Keyword.get(merged_opts, :implementation_model),
          System.get_env("JEV_PLANNING_MODEL"),
          System.get_env("JEV_IMPLEMENTATION_MODEL")
        ],
        &is_binary/1
      )

    if not explicit_models? and not SuperPi.AI.GeminiClient.configured?() do
      {:ok, derived_context}
    else
      planning_model =
        Keyword.get(merged_opts, :planning_model) ||
          System.get_env("JEV_PLANNING_MODEL") ||
          @default_planning_model

      implementation_model =
        Keyword.get(merged_opts, :implementation_model) ||
          System.get_env("JEV_IMPLEMENTATION_MODEL") ||
          @default_implementation_model

      edit_tools = Keyword.get(merged_opts, :edit_tools, @default_edit_tools)

      messages = Map.get(derived_context, :messages, [])
      phase = determine_phase(messages, edit_tools)

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
  end

  @doc """
  Determines the current work phase (:planning or :implementation) by inspecting
  whether any edit tools have been called in previous turns.
  """
  def determine_phase(messages, edit_tools \\ @default_edit_tools)

  def determine_phase(messages, edit_tools) when is_list(messages) do
    has_edit_call? =
      Enum.any?(messages, fn msg ->
        case msg do
          %{"role" => "assistant", "content" => blocks} when is_list(blocks) ->
            Enum.any?(blocks, fn
              %{"type" => "tool_call", "name" => name} -> name in edit_tools
              _ -> false
            end)

          %{"role" => "tool", "name" => name} ->
            name in edit_tools

          _ ->
            false
        end
      end)

    if has_edit_call?, do: :implementation, else: :planning
  end

  def determine_phase(_, _), do: :planning
end
