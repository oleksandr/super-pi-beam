defmodule SuperPi.Auth do
  @moduledoc """
  Bearer-token authentication and conversation ownership for the Gateway and RPC server.

  ## Tokens

  Configure tokens with `config :super_pi, gateway_tokens: [...]` or the
  `SUPER_PI_GATEWAY_TOKEN` environment variable (comma separated). An entry is either a
  token string or a `{name, token}` pair. A named entry makes the principal readable in
  logs and ownership records. An unnamed token gets the principal `token:<hash prefix>`.
  The older single `:gateway_token` key still works.

  With no tokens configured the endpoints are open, which is safe only on a loopback
  address. `SuperPi.Gateway.Server` refuses to start on another address without a token.
  Open endpoints use the principal `"anonymous"`.

  ## Ownership

  The first principal to create a conversation owns it (`pi.owner` document). Another
  principal gets `:not_found` for it, the same answer as for a conversation that does not
  exist, so an id does not reveal that a conversation exists. A conversation with no
  owner (created by the CLI, or before this check existed) belongs to `"anonymous"`, so
  it is reachable only when authentication is off.
  """

  alias SuperPi.Durable.{Doc, Storage}

  @anonymous "anonymous"

  @doc "Principal used when authentication is off."
  def anonymous, do: @anonymous

  @doc "Returns `%{token => principal}` from config and environment."
  @spec tokens() :: %{String.t() => String.t()}
  def tokens do
    configured =
      Application.get_env(:super_pi, :gateway_tokens, []) ++
        List.wrap(Application.get_env(:super_pi, :gateway_token)) ++
        env_tokens()

    configured
    |> Enum.flat_map(fn
      {name, token} when is_binary(token) and token != "" -> [{token, to_string(name)}]
      token when is_binary(token) and token != "" -> [{token, "token:" <> fingerprint(token)}]
      _ -> []
    end)
    |> Map.new()
  end

  @doc "True when at least one token is configured."
  def required?, do: tokens() != %{}

  @doc """
  Checks a presented token. Returns `{:ok, principal}` or `:error`.
  With no tokens configured, any call (including a missing token) is `{:ok, "anonymous"}`.
  """
  @spec authenticate(String.t() | nil) :: {:ok, String.t()} | :error
  def authenticate(presented) do
    case tokens() do
      known when map_size(known) == 0 ->
        {:ok, @anonymous}

      known ->
        # Compare against every token so the time taken does not depend on which one matched.
        Enum.reduce(known, :error, fn {token, principal}, acc ->
          if is_binary(presented) and Plug.Crypto.secure_compare(token, presented),
            do: {:ok, principal},
            else: acc
        end)
    end
  end

  @doc "Extracts the token from an `Authorization: Bearer ...` header value."
  def bearer_token("Bearer " <> token), do: String.trim(token)
  def bearer_token("bearer " <> token), do: String.trim(token)
  def bearer_token(_), do: nil

  @doc "Records `principal` as the owner of `conversation_id`."
  def claim!(conversation_id, principal) when is_binary(principal) do
    Storage.commit(fn seq ->
      Doc.put_doc("conversation", conversation_id, "pi.owner", %{"principal" => principal}, seq)
    end)

    :ok
  end

  @doc "Owner of a conversation (`\"anonymous\"` when none is recorded)."
  def owner(conversation_id) do
    case Doc.snapshot("conversation", conversation_id, "pi.owner") do
      %{"principal" => principal} when is_binary(principal) -> principal
      _ -> @anonymous
    end
  end

  @doc "True when `principal` may use the conversation."
  def authorized?(conversation_id, principal), do: owner(conversation_id) == principal

  defp env_tokens do
    case System.get_env("SUPER_PI_GATEWAY_TOKEN") do
      nil -> []
      value -> value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    end
  end

  defp fingerprint(token) do
    :crypto.hash(:sha256, token) |> Base.encode16(case: :lower) |> binary_part(0, 8)
  end
end
