defmodule SuperPi.AI.Providers.Mock do
  @moduledoc """
  Echo provider for tests and demos. Active only when `config :super_pi, mock_llm: true`.

  It replies with `"Echo: <last user text>"` and reports fixed token usage.
  """

  @behaviour SuperPi.AI.Provider

  @impl true
  def id, do: "mock"

  @impl true
  def handles?(_model), do: true

  @impl true
  def configured?, do: true

  @impl true
  def models, do: [%{"id" => "mock", "label" => "Echo mock (tests only)"}]

  @impl true
  def generate(payload, opts) do
    # `mock_llm_delay_ms` makes a turn last long enough for a test to interrupt it.
    case Application.get_env(:super_pi, :mock_llm_delay_ms, 0) do
      ms when is_integer(ms) and ms > 0 -> Process.sleep(ms)
      _ -> :ok
    end

    on_delta = Keyword.get(opts, :on_delta, fn _ -> :ok end)

    user_text =
      payload
      |> Map.get(:messages, [])
      |> Enum.reverse()
      |> Enum.find(&(&1["role"] == "user"))
      |> case do
        %{"content" => [%{"text" => t} | _]} -> t
        %{"content" => t} when is_binary(t) -> t
        _ -> ""
      end

    reply = "Echo: #{user_text}"
    on_delta.({:text_delta, 0, reply})

    {:ok,
     %{
       "role" => "assistant",
       "content" => [%{"type" => "text", "text" => reply}],
       "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
     }}
  end
end
