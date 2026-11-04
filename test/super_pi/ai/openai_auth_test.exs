defmodule SuperPi.AI.OpenAIAuthTest do
  use ExUnit.Case, async: false

  alias SuperPi.AI.Provider
  alias SuperPi.AI.Providers.OpenAI
  alias SuperPi.AI.Providers.OpenAI.Auth

  @moduletag :tmp_dir
  @keys [
    :openai_api_key,
    :openai_auth_command,
    :openai_auth_timeout_ms,
    :openai_auth_cache_ttl_ms
  ]

  setup %{tmp_dir: dir} do
    saved = Enum.map(@keys, &{&1, Application.fetch_env(:super_pi, &1)})
    api_key = System.get_env("OPENAI_API_KEY")
    Enum.each(@keys, &Application.delete_env(:super_pi, &1))
    System.delete_env("OPENAI_API_KEY")

    on_exit(fn ->
      Enum.each(saved, fn
        {key, {:ok, value}} -> Application.put_env(:super_pi, key, value)
        {key, :error} -> Application.delete_env(:super_pi, key)
      end)

      if api_key,
        do: System.put_env("OPENAI_API_KEY", api_key),
        else: System.delete_env("OPENAI_API_KEY")
    end)

    {:ok, command: Path.join(dir, "token")}
  end

  defp script(command, body) do
    File.write!(command, "#!/bin/sh\n" <> body)
    File.chmod!(command, 0o700)
    Application.put_env(:super_pi, :openai_auth_command, command)
  end

  test "concurrent requests reuse the cached stdout token and ignore stderr diagnostics", %{
    command: command
  } do
    script(
      command,
      ~s(printf x >> "$0.count"\nprintf 'refreshing login\\n' >&2\nprintf bearer-token)
    )

    tasks = for _ <- 1..5, do: Task.async(fn -> Auth.token(command) end)
    assert Enum.map(tasks, &Task.await/1) == List.duplicate({:ok, "bearer-token"}, 5)
    assert File.read!(command <> ".count") == "x"
  end

  test "refreshes opaque tokens after the cache TTL", %{command: command} do
    Application.put_env(:super_pi, :openai_auth_cache_ttl_ms, 20)
    script(command, ~s(cat "$0.value"))
    File.write!(command <> ".value", "first")
    assert {:ok, "first"} = Auth.token(command)
    File.write!(command <> ".value", "second")
    Process.sleep(30)
    assert {:ok, "second"} = Auth.token(command)
  end

  test "does not cache JWTs near expiry and rejects expired JWTs", %{command: command} do
    script(command, ~s(cat "$0.value"))
    near_expiry = jwt(System.system_time(:second) + 10)
    File.write!(command <> ".value", near_expiry)
    assert {:ok, ^near_expiry} = Auth.token(command)
    File.write!(command <> ".value", jwt(System.system_time(:second) - 1))
    assert {:error, :openai_auth_expired} = Auth.token(command)
  end

  test "a failed command exposes its exit status and stderr through the provider", %{
    command: command
  } do
    script(command, "printf 'login expired' >&2\nexit 7")
    assert {:error, reason} = OpenAI.generate(%{model: "gpt-6-astra"}, [])
    assert reason == {:openai_auth_failed, 7, "login expired"}
    assert Provider.format_error(reason) == "OpenAI auth command failed (exit 7): login expired"
    script(command, "printf renewed-token")
    assert {:ok, "renewed-token"} = Auth.token(command)
  end

  test "a hanging command returns a timeout and the cache server stays usable", %{
    command: command
  } do
    Application.put_env(:super_pi, :openai_auth_timeout_ms, 100)
    script(command, "exec sleep 3")
    {elapsed, result} = :timer.tc(fn -> OpenAI.generate(%{model: "gpt-6-astra"}, []) end)
    assert result == {:error, {:openai_auth_timeout, 100}}
    assert elapsed < 2_000_000
    Application.put_env(:super_pi, :openai_auth_timeout_ms, 2_000)
    script(command, "printf recovered-token")
    assert {:ok, "recovered-token"} = Auth.token(command)
  end

  test "an absent executable and an empty token report the cause", %{command: command} do
    assert {:error, {:openai_auth_failed, :not_found, _}} = Auth.token(command)
    script(command, "exit 0")

    assert {:error, {:openai_auth_failed, 0, "command returned an empty token"}} =
             Auth.token(command)
  end

  test "the command receives EOF on stdin", %{command: command} do
    script(command, "cat >/dev/null\nprintf token-after-eof")
    assert {:ok, "token-after-eof"} = Auth.token(command)
  end

  test "excessive token output stops collection with an explicit error", %{command: command} do
    script(command, "printf '%65537s' x")

    assert {:error, {:openai_auth_failed, :output_limit, "token exceeds 64 KiB"}} =
             Auth.token(command)
  end

  defp jwt(exp),
    do:
      "header." <>
        Base.url_encode64(Jason.encode!(%{"exp" => exp}), padding: false) <> ".signature"
end
