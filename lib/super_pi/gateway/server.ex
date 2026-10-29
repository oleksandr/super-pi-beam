defmodule SuperPi.Gateway.Server do
  @moduledoc """
  SuperPi HTTP Gateway Server for OpenAI-compatible client integrations (`REQ-GATEWAY-01`).
  Starts Bandit serving `SuperPi.Gateway.Router` on a configured port (default 4000).
  """

  def child_spec(opts) do
    port = Keyword.get(opts, :port) || Application.get_env(:super_pi, :gateway_port, 4000)
    ip = Keyword.get(opts, :ip, {127, 0, 0, 1})
    token = Keyword.get(opts, :auth_token) || Application.get_env(:super_pi, :gateway_token)

    loopback? =
      case ip do
        {127, _, _, _} -> true
        {0, 0, 0, 0, 0, 0, 0, 1} -> true
        _ -> false
      end

    if not loopback? and (is_nil(token) or token == "") do
      raise ArgumentError, "Binding gateway to a non-loopback address requires a configured auth token"
    end

    Bandit.child_spec(
      plug: SuperPi.Gateway.Router,
      scheme: :http,
      port: port,
      ip: ip
    )
  end
end
