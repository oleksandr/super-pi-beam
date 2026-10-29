defmodule SuperPi.Harness.AGY.Extensions.SlashCommands do
  @moduledoc """
  Antigravity Slash-Command & Skill Expansion Extension (`SuperPi.Extension` behaviour).

  Intercepts `on_input/2` unless `"disableSlashCommands" => true` is set (`--disable-slash-commands`):
  - `/plan <task>` — Rewrites the prompt into structured step-by-step planning mode.
  - `/goal <task>` — Rewrites the prompt into autonomous thorough completion mode and enables goal verification.
  - `/boost <task>` — Enables deep multi-perspective analysis.
  - `/model <model_id>` — Updates `pi.agent` model and handles the command without calling the LLM (`:handled`).
  - `/mode <auto|accept-edits|plan>` — Updates `pi.agent` `executionMode` (`:handled`).
  """

  use SuperPi.Extension

  alias SuperPi.Durable.{Doc, Storage}

  @impl true
  def on_input(input, ctx) do
    agent_cfg = Doc.snapshot("conversation", ctx.conversation_id, "pi.agent") || %{}

    if Map.get(agent_cfg, "disableSlashCommands", false) == true do
      :continue
    else
      trimmed = String.trim(input)

      cond do
        String.starts_with?(trimmed, "/model ") ->
          new_model = trimmed |> String.replace_prefix("/model ", "") |> String.trim()
          Storage.configure_agent!(ctx.conversation_id, %{"model" => new_model})
          :handled

        String.starts_with?(trimmed, "/mode ") ->
          new_mode = trimmed |> String.replace_prefix("/mode ", "") |> String.trim()
          Storage.configure_agent!(ctx.conversation_id, %{"executionMode" => new_mode})
          :handled

        String.starts_with?(trimmed, "/plan ") ->
          rest = trimmed |> String.replace_prefix("/plan ", "") |> String.trim()
          Storage.configure_agent!(ctx.conversation_id, %{"executionMode" => "plan"})

          expanded =
            "[MODE: PLAN] Create a clear, step-by-step implementation plan with verification gates before making any changes:\n" <>
              rest

          {:transform, expanded, []}

        String.starts_with?(trimmed, "/goal ") ->
          rest = trimmed |> String.replace_prefix("/goal ", "") |> String.trim()

          expanded =
            "[MODE: GOAL] Execute this task thoroughly until the goal is 100% verified and complete:\n" <>
              rest

          {:transform, expanded, []}

        String.starts_with?(trimmed, "/boost ") ->
          rest = trimmed |> String.replace_prefix("/boost ", "") |> String.trim()

          expanded =
            "[MODE: BOOST] Apply deep architectural reasoning, multiple perspectives, and rigorous verification:\n" <>
              rest

          {:transform, expanded, []}

        true ->
          :continue
      end
    end
  end
end
