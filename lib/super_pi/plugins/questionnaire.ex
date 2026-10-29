defmodule SuperPi.Plugins.Questionnaire do
  @moduledoc """
  Questionnaire Plugin (migrated from Pi ecosystem `questionnaire.ts` & `question.ts`).

  Registers the `ask_question` tool allowing agents to request structured clarifications
  from the user (multiple choice with recommended default or free-form options),
  preventing hallucinated assumptions during complex workflows.
  """

  use SuperPi.Extension

  def id, do: "questionnaire"
  def name, do: "Questionnaire & Human Clarification"
  def description, do: "Structured human-in-the-loop clarification tool with recommended options"

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

  @impl true
  def before_agent_start(agent_cfg, _ctx) do
    existing_tools = Map.get(agent_cfg, "tools", [])

    updated_tools =
      if Enum.any?(existing_tools, &(&1["name"] == "ask_question")) do
        existing_tools
      else
        existing_tools ++ [@tool_spec]
      end

    {:ok, Map.put(agent_cfg, "tools", updated_tools)}
  end

  @impl true
  def wrap_tool("ask_question", args, _next, ctx) do
    args = if is_map(args), do: args, else: %{}

    questions =
      case Map.get(args, "questions") || Map.get(args, :questions) do
        list when is_list(list) -> list
        item when is_map(item) -> [item]
        str when is_binary(str) -> [%{"question" => str}]
        _ -> []
      end

    answers_override = Map.get(ctx, :questionnaire_answers) || %{}

    answers =
      Enum.map(questions, fn
        q when is_map(q) ->
          q_text = Map.get(q, "question") || Map.get(q, :question) || ""

          options =
            case Map.get(q, "options") || Map.get(q, :options) do
              list when is_list(list) -> list
              str when is_binary(str) -> [str]
              _ -> []
            end

          selected =
            case Map.get(answers_override, q_text) do
              val when not is_nil(val) -> val
              _ -> List.first(options) || "No answer provided"
            end

          %{
            "question" => q_text,
            "selected" => selected
          }

        other ->
          q_text = to_string(other)
          %{
            "question" => q_text,
            "selected" => Map.get(answers_override, q_text, "No answer provided")
          }
      end)

    rendered =
      Enum.map_join(answers, "\n\n", fn a ->
        "Question: #{a["question"]}\nUser Answer: #{a["selected"]}"
      end)

    %{
      "output" => "Clarification received:\n" <> rendered,
      "structured_output" => %{"answers" => answers},
      "details" => %{"question_count" => length(questions)}
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
