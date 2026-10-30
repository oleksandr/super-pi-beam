defmodule SuperPi.Plugins.Questionnaire do
  @moduledoc """
  Questionnaire Plugin (migrated from Pi ecosystem `questionnaire.ts` & `question.ts`).

  Adds the `ask_question` tool. A call publishes the questions as a `ui_request` event and
  waits for a client to answer (`SuperPi.UI.Broker`). The CLI chat asks on the terminal. An
  RPC client that watches the conversation receives the event and answers with `ui.respond`.

  - With no client able to answer (the HTTP gateway, a headless run), the call returns an
    error at once. The model is not given invented answers.
  - The wait ends after `config :super_pi, questionnaire_timeout_ms` (default 10 minutes) or
    when the conversation is cancelled.
  - A pending question is not stored. After a crash the turn restarts and the model asks again.
  - `ctx[:questionnaire_answers]` (a map of question text to selected option) answers without
    asking. It is for headless runs and tests, and the output says the answers were preset.

  While a question waits, the conversation process is blocked in the tool call, so a `steer`
  message is handled only after the answer. `session.cancel` ends the wait.
  """

  use SuperPi.Extension
  def id, do: "questionnaire"
  def name, do: "Questionnaire & Human Clarification"
  def description, do: "Asks the user multiple-choice questions through a connected client"

  @tool_spec %{
    "name" => "ask_question",
    "effects" => ["read"],
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
                "description" =>
                  "List of available choices, with '(Recommended)' on the first option"
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
    existing_tools = Map.get(agent_cfg, "tools") || []

    if Enum.any?(existing_tools, &(&1["name"] == "ask_question")) do
      {:ok, agent_cfg}
    else
      {:ok, Map.put(agent_cfg, "tools", existing_tools ++ [@tool_spec])}
    end
  end

  @impl true
  def wrap_tool("ask_question", args, _next, ctx) do
    questions = normalize_questions(args)
    overrides = Map.get(ctx, :questionnaire_answers) || %{}
    texts = Enum.map(questions, &question_text/1)

    cond do
      questions == [] or Enum.any?(texts, &(&1 == "")) ->
        error(
          "ask_question needs a non-empty `questions` list, and every question needs text",
          "invalid_arguments"
        )

      Enum.all?(texts, &Map.has_key?(overrides, &1)) ->
        answers = Enum.map(texts, &%{"question" => &1, "selected" => Map.fetch!(overrides, &1)})
        result(answers, "override", "(preset override, not asked)")

      true ->
        ask(questions, ctx)
    end
  end

  def wrap_tool(_name, args, next, _ctx) do
    next.(args)
  end

  @doc """
  Returns the tool specification map for direct registration.
  """
  def tool_spec, do: @tool_spec

  defp ask(questions, ctx) do
    timeout = Application.get_env(:super_pi, :questionnaire_timeout_ms, 600_000)
    request = %{"kind" => "questionnaire", "questions" => questions}

    case SuperPi.UI.Broker.ask(Map.get(ctx, :conversation_id), request, timeout) do
      {:ok, value} ->
        case normalize_answers(value, questions) do
          {:ok, answers} ->
            result(answers, "user", "")

          :error ->
            error(
              "The client answered with an unusable value: #{inspect(value)}",
              "invalid_answer"
            )
        end

      {:error, :no_interactive_client} ->
        error(
          "No interactive client is connected to this conversation, so the user cannot be asked. " <>
            "Make the decision yourself or state your assumption. The HTTP gateway cannot prompt a user.",
          "no_interactive_client"
        )

      {:error, :cancelled} ->
        error("The question was cancelled.", "cancelled")

      {:error, :timeout} ->
        error("The user did not answer in time.", "timeout")
    end
  end

  # A client may answer with a list of `%{"question", "selected"}`, a map of question to
  # selection, or (for a single question) the selection itself.
  defp normalize_answers(value, questions) do
    texts = Enum.map(questions, &question_text/1)

    case value do
      list when is_list(list) and list != [] ->
        cond do
          Enum.all?(list, &(is_map(&1) and Map.has_key?(&1, "selected"))) ->
            {:ok, Enum.map(list, &%{"question" => &1["question"], "selected" => &1["selected"]})}

          # A multi-select answer to a single question.
          length(texts) == 1 and Enum.all?(list, &is_binary/1) ->
            {:ok, [%{"question" => hd(texts), "selected" => list}]}

          true ->
            :error
        end

      %{} = map when map_size(map) > 0 ->
        {:ok, Enum.map(map, fn {q, sel} -> %{"question" => q, "selected" => sel} end)}

      single when (is_binary(single) or is_list(single)) and length(texts) == 1 ->
        {:ok, [%{"question" => hd(texts), "selected" => single}]}

      _ ->
        :error
    end
  end

  defp result(answers, source, note) do
    rendered =
      Enum.map_join(answers, "\n\n", fn a ->
        "Question: #{a["question"]}\nAnswer#{if note == "", do: "", else: " " <> note}: #{format_selected(a["selected"])}"
      end)

    %{
      "output" => rendered,
      "structured_output" => %{"answers" => answers, "source" => source},
      "details" => %{"question_count" => length(answers), "source" => source}
    }
  end

  defp format_selected(list) when is_list(list), do: Enum.join(list, ", ")
  defp format_selected(other), do: to_string(other)

  defp error(message, status) do
    %{
      "output" => message,
      "structured_output" => %{"error" => message, "status" => status},
      "details" => %{"status" => status},
      "is_error" => true
    }
  end

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
