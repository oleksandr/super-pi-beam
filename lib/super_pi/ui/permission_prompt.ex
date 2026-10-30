defmodule SuperPi.UI.PermissionPrompt do
  @moduledoc """
  Asks a human whether a blocked tool call may run. Used by `SuperPi.Plugins.Permissions` and
  `SuperPi.Plugins.Hooks`.

  The question travels as a `permission_request` event through `SuperPi.UI.Broker`. The answer is
  the `option_id` of one of the four options (ACP `PermissionOptionKind`): `allow_once`,
  `allow_always`, `reject_once`, `reject_always`.

  **Fail closed.** `ask/2` returns `:unavailable` when no client can answer, when the question times
  out or is cancelled, and when the answer cannot be read. A caller treats `:unavailable` exactly like
  the block that it would have returned without a prompt, with the same message. Prompting is on by
  default and `config :super_pi, :permissions, interactive_prompts: false` turns it off.
  """

  alias SuperPi.UI.Broker

  @type answer :: :allow_once | :allow_always | :reject_once | :reject_always | :unavailable

  @doc "True when prompts are enabled in `settings`."
  @spec enabled?(map()) :: boolean()
  def enabled?(settings), do: Map.get(settings, "interactive_prompts", true) != false

  @doc "True when a prompt can be shown now: enabled, and a client answers for the conversation."
  @spec available?(integer() | nil, map()) :: boolean()
  def available?(nil, _settings), do: false

  def available?(conversation_id, settings),
    do: enabled?(settings) and Broker.responder?(conversation_id)

  @doc """
  Asks about one tool call. `fields` has `"tool_name"`, `"arguments"`, `"reason"` and `"risk"`.
  `ctx` supplies `:conversation_id`, `:tool_call_id` and `:turn_id`.
  """
  @spec ask(map(), map()) :: answer()
  def ask(ctx, fields) do
    timeout = Application.get_env(:super_pi, :permission_prompt_timeout_ms, 120_000)

    request =
      fields
      |> Map.take(["tool_name", "arguments", "reason", "risk"])
      |> Map.merge(%{
        "tool_call_id" => Map.get(ctx, :tool_call_id),
        "options" => SuperPi.Event.permission_options()
      })

    case Broker.ask(Map.get(ctx, :conversation_id), request, timeout,
           event: :permission_request,
           turn_id: Map.get(ctx, :turn_id)
         ) do
      {:ok, value} -> parse(value)
      {:error, _} -> :unavailable
    end
  end

  @doc false
  @spec parse(term()) :: answer()
  def parse("allow_once"), do: :allow_once
  def parse("allow_always"), do: :allow_always
  def parse("reject_once"), do: :reject_once
  def parse("reject_always"), do: :reject_always
  def parse(%{"option_id" => id}), do: parse(id)
  def parse(%{"optionId" => id}), do: parse(id)
  def parse(%{"selected" => id}), do: parse(id)
  # ACP: `{"outcome": {"outcome": "selected", "optionId": "allow_once"}}`
  def parse(%{"outcome" => %{} = outcome}), do: parse(outcome)
  def parse(_), do: :unavailable
end
