defmodule SuperPi.Plugins.Questionnaire do
  @moduledoc """
  Questionnaire Plugin (migrated from Pi ecosystem `questionnaire.ts` & `question.ts`).

  Not implemented. No client channel asks a real user yet, so the plugin does not advertise
  `ask_question`. A call returns a `not_implemented` error, unless the caller sets
  `ctx[:questionnaire_answers]` with an answer for every question. That override is for
  headless runs and tests, and the output says the answers were preset.
  """

  use SuperPi.Extension
  alias SuperPi.Tools

  def id, do: "questionnaire"
  def name, do: "Questionnaire & Human Clarification"
  def description, do: "Human clarification tool (not implemented: calls return a not_implemented error)"

  @tool_spec %{
    "name" => "ask_question",
    "description" =>
      "Ask the user one or more multiple-choice questions to clarify requirements, design decisions, or ambiguous preferences. Always provide a recommended option prefixed with '(Recommended)'.",
    "parameters" => %{
      "type" => "object",
      "properties" => %{
        "questions" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "question" => %{"type" => "string", "description" => "The question prompt"},
              "options" => %{
                "type" => "array",
                "items" => %{"type" => "string"},
                "description" => "List of available choices, with '(Recommended)' on the first option"
              },
              "is_multi_select" => %{
                "type" => "boolean",
                "description" => "Whether multiple choices may be selected"
              }
            },
            "required" => ["question", "options"]
          },
          "description" => "Questions to present to the user"
        }
      },
      "required" => ["questions"]
    }
  }

  # The tool is not advertised: nothing asks a real user yet. Register `tool_spec/0` here
  # again when a client channel can answer (Task 34 on the project board).
  @impl true
  def before_agent_start(agent_cfg, _ctx), do: {:ok, agent_cfg}

  @impl true
  def wrap_tool("ask_question", args, _next, ctx) do
    questions = normalize_questions(args)
    overrides = Map.get(ctx, :questionnaire_answers) || %{}

    texts = Enum.map(questions, &question_text/1)

    if texts != [] and Enum.all?(texts, &Map.has_key?(overrides, &1)) do
      answers = Enum.map(texts, &%{"question" => &1, "selected" => Map.fetch!(overrides, &1)})

      rendered =
        Enum.map_join(answers, "\n\n", fn a ->
          "Question: #{a["question"]}\nAnswer (preset override, not asked): #{a["selected"]}"
        end)

      %{
        "output" => "Preset answers used:\n" <> rendered,
        "structured_output" => %{"answers" => answers, "source" => "override"},
        "details" => %{"question_count" => length(questions), "source" => "override"}
      }
    else
      Tools.not_implemented_result("ask_question")
    end
  end

  def wrap_tool(_name, args, next, _ctx) do
    next.(args)
  end

  @doc """
  Returns the tool specification map for direct registration.
  """
  def tool_spec, do: @tool_spec

  defp normalize_questions(args) when is_map(args) do
    case Map.get(args, "questions") || Map.get(args, :questions) do
      list when is_list(list) -> list
      item when is_map(item) -> [item]
      str when is_binary(str) -> [%{"question" => str}]
      _ -> []
    end
  end

  defp normalize_questions(_), do: []

  defp question_text(q) when is_map(q), do: Map.get(q, "question") || Map.get(q, :question) || ""
  defp question_text(other), do: to_string(other)
end
