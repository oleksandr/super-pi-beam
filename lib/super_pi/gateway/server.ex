defmodule SuperPi.Gateway.Server do
  @moduledoc """
  SuperPi HTTP Gateway Server for OpenAI-compatible client integrations (`REQ-GATEWAY-01`).
  Starts Bandit serving `SuperPi.Gateway.Router` on a configured port (default 4000).
  """

  def child_spec(opts) do
    port = Keyword.get(opts, :port) || Application.get_env(:super_pi, :gateway_port, 4000)
    ip = Keyword.get(opts, :ip, {127, 0, 0, 1})
    token = Keyword.get(opts, :auth_token)
    authenticated? = SuperPi.Auth.required?() or (is_binary(token) and token != "")

    loopback? =
      case ip do
        {127, _, _, _} -> true
        {0, 0, 0, 0, 0, 0, 0, 1} -> true
        _ -> false
      end

    if not loopback? and not authenticated? do
      raise ArgumentError,
            "Binding gateway to a non-loopback address requires a token " <>
              "(config :super_pi, gateway_tokens: [...] or SUPER_PI_GATEWAY_TOKEN)"
    end

    # An explicit `auth_token:` option joins the configured tokens.
    if is_binary(token) and token != "" do
      Application.put_env(:super_pi, :gateway_token, token)
    end

    Bandit.child_spec(
      plug: SuperPi.Gateway.Router,
      scheme: :http,
      port: port,
      ip: ip
    )
  end
end
