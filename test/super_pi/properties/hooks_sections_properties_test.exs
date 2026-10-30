defmodule SuperPi.Properties.HooksSectionsTest do
  @moduledoc """
  Properties of the SessionStart section handling in `SuperPi.Plugins.Hooks`.

  Older versions stored the section as `agy_session_start_hooks`. Whatever mix of old, new and
  unrelated sections a conversation holds, one run must leave at most one current section, no
  old one, and every unrelated section in its place.
  """
  use SuperPi.DataCase, async: false
  use ExUnitProperties

  alias SuperPi.Durable.Storage
  alias SuperPi.Plugins.Hooks

  @current "session_start_hooks"
  @legacy "agy_session_start_hooks"

  setup_all do
    dir = Path.join(System.tmp_dir!(), "hooks_props_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    injecting = Path.join(dir, "inject.json")

    File.write!(
      injecting,
      Jason.encode!(%{"p" => %{"SessionStart" => [%{"command" => ~s(echo '{"injectSteps":[{"systemMessage":{"systemMessage":"hello"}}]}')}]}})
    )

    silent = Path.join(dir, "silent.json")
    File.write!(silent, Jason.encode!(%{"p" => %{"SessionStart" => [%{"command" => "echo '{}'"}]}}))

    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, injecting: injecting, silent: silent}
  end

  defp sections do
    section =
      one_of([
        map(string(:alphanumeric, min_length: 1, max_length: 6), &%{"id" => "x_" <> &1, "content" => &1}),
        constant(%{"id" => @current, "content" => "old content"}),
        constant(%{"id" => @legacy, "content" => "legacy content"})
      ])

    list_of(section, max_length: 6)
  end

  defp run(cfg, file, dir) do
    conv = Storage.create_conversation!()
    Hooks.before_agent_start(Map.merge(cfg, %{"hooksFiles" => [file], "workspacePaths" => [dir]}), %{conversation_id: conv.id})
  end

  defp ids(cfg), do: cfg |> Map.get("systemSections", []) |> Enum.map(& &1["id"])

  property "when a hook injects text, one current section remains and no legacy section", ctx do
    check all(secs <- sections(), max_runs: 40) do
      {:ok, out} = run(%{"systemSections" => secs}, ctx.injecting, ctx.dir)

      assert Enum.count(ids(out), &(&1 == @current)) == 1
      refute @legacy in ids(out)

      unrelated = fn list -> Enum.reject(list, &(&1["id"] in [@current, @legacy])) end
      assert unrelated.(out["systemSections"]) == unrelated.(secs)
    end
  end

  property "when no hook injects text, no legacy section remains and nothing else changes", ctx do
    check all(secs <- sections(), max_runs: 40) do
      {:ok, out} = run(%{"systemSections" => secs}, ctx.silent, ctx.dir)

      refute @legacy in ids(out)
      assert Enum.reject(secs, &(&1["id"] == @legacy)) == Map.get(out, "systemSections", [])
    end
  end

  property "running the hook again gives the same sections", ctx do
    check all(secs <- sections(), file <- member_of([:injecting, :silent]), max_runs: 40) do
      cfg = %{"systemSections" => secs}
      {:ok, once} = run(cfg, Map.fetch!(ctx, file), ctx.dir)
      {:ok, twice} = run(once, Map.fetch!(ctx, file), ctx.dir)
      assert twice == once
    end
  end
end
