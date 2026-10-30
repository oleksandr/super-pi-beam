defmodule SuperPi.AI.ProviderFormatErrorTest do
  @moduledoc """
  `SuperPi.AI.Provider.format_error/1` gives readable text. A provider message with quotes or
  JSON must reach the client without escape backslashes, also when formatted twice.
  """
  use ExUnit.Case, async: true

  alias SuperPi.AI.Provider

  @message ~s(Invalid value: "tools[0].name" must match "^[a-z]+$")

  test "HTTP errors keep the provider message unescaped" do
    assert Provider.format_error({:http_error, 400, @message}) == "HTTP 400: " <> @message
  end

  test "formatting twice changes nothing" do
    once = Provider.format_error({:http_error, 400, @message})
    assert Provider.format_error(once) == once
    refute once =~ "\\"
  end

  test "stream errors show the reason" do
    assert Provider.format_error({:stream_error, %{reason: @message, retryable: false}}) ==
             "Stream error: " <> @message
  end

  test "Gemini HTTP errors take the message from the body or the raw stream" do
    body = %{"error" => %{"message" => @message}}
    assert Provider.format_error({:gemini_http_error, 400, body, ""}) == "HTTP 400: " <> @message

    raw = Jason.encode!([body])
    assert Provider.format_error({:gemini_http_error, 400, nil, raw}) == "HTTP 400: " <> @message
  end

  test "exceptions use their message" do
    assert Provider.format_error(%Req.TransportError{reason: :econnrefused}) ==
             "connection refused"
  end

  test "other terms fall back to inspect" do
    assert Provider.format_error({:unknown, 1}) == "{:unknown, 1}"
  end
end
