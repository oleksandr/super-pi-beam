defmodule SuperPi.Properties.DiscoveryTest do
  @moduledoc """
  Properties of skill discovery tiers and of directory resolution (`SuperPi.Discovery`).
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias SuperPi.Discovery

  @names ["alpha", "beta", "gamma", "delta", "eps"]

  setup do
    keys = [:app_data_dir, :global_config_dir, :discovery_roots]
    saved = Enum.map(keys, &{&1, Application.fetch_env(:super_pi, &1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {k, {:ok, v}} -> Application.put_env(:super_pi, k, v)
        {k, :error} -> Application.delete_env(:super_pi, k)
      end)

      for v <- ["SUPER_PI_DATA_DIR", "SUPER_PI_CONFIG_DIR", "SUPER_PI_DISCOVERY_ROOTS"], do: System.delete_env(v)
    end)

    Enum.each(keys, &Application.delete_env(:super_pi, &1))
    for v <- ["SUPER_PI_DATA_DIR", "SUPER_PI_CONFIG_DIR", "SUPER_PI_DISCOVERY_ROOTS"], do: System.delete_env(v)
    :ok
  end

  defp write_skill!(root, name, marker) do
    dir = Path.join([root, name])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "SKILL.md"), "---\nname: #{name}\ndescription: #{marker}\n---\nbody")
  end

  defp name_set, do: map(list_of(member_of(@names), max_length: 5), &Enum.uniq/1)

  property "for each skill name the highest tier wins, and no name appears twice" do
    check all(
            workspace <- name_set(),
            global <- name_set(),
            extra1 <- name_set(),
            extra2 <- name_set(),
            max_runs: 40
          ) do
      tmp = Path.join(System.tmp_dir!(), "disc_props_#{System.unique_integer([:positive])}")
      ws = Path.join(tmp, "ws")
      glob = Path.join(tmp, "global")
      e1 = Path.join(tmp, "extra1")
      e2 = Path.join(tmp, "extra2")
      File.mkdir_p!(ws)

      for {root, names, marker} <- [
            {Path.join([ws, ".agents", "skills"]), workspace, "workspace"},
            {Path.join(glob, "skills"), global, "global"},
            {Path.join(e1, "skills"), extra1, "extra1"},
            {Path.join(e2, "skills"), extra2, "extra2"}
          ],
          name <- names do
        write_skill!(root, name, marker)
      end

      Application.put_env(:super_pi, :global_config_dir, glob)
      Application.put_env(:super_pi, :discovery_roots, [e1, e2])
      skills = Discovery.discover_skills([ws], app_data_dir: Path.join(tmp, "data"))

      found = Enum.map(skills, & &1.name)
      assert found == Enum.uniq(found)

      expected =
        for name <- Enum.uniq(workspace ++ global ++ extra1 ++ extra2), into: %{} do
          marker =
            cond do
              name in workspace -> "workspace"
              name in global -> "global"
              name in extra1 -> "extra1"
              true -> "extra2"
            end

          {name, marker}
        end

      assert Map.new(skills, &{&1.name, &1.description}) == expected
      File.rm_rf!(tmp)
    end
  end

  property "directory resolution is: app env, then environment variable, then the OS default" do
    check all(app? <- boolean(), env? <- boolean(), max_runs: 40) do
      Application.delete_env(:super_pi, :app_data_dir)
      System.delete_env("SUPER_PI_DATA_DIR")
      if app?, do: Application.put_env(:super_pi, :app_data_dir, "/p/app")
      if env?, do: System.put_env("SUPER_PI_DATA_DIR", "/p/env")

      expected =
        cond do
          app? -> "/p/app"
          env? -> "/p/env"
          true -> nil
        end

      case expected do
        nil ->
          dir = Discovery.default_app_data_dir()
          assert dir =~ "super-pi"
          refute dir =~ ".gemini"

        path ->
          assert Discovery.default_app_data_dir() == path
      end
    end
  end

  property "extra roots from the environment keep their order and are expanded" do
    check all(roots <- list_of(member_of(["/r/one", "/r/two", "/r/three"]), min_length: 1, max_length: 3), max_runs: 30) do
      sep = if match?({:win32, _}, :os.type()), do: ";", else: ":"
      Application.delete_env(:super_pi, :discovery_roots)
      System.put_env("SUPER_PI_DISCOVERY_ROOTS", Enum.join(roots, sep))
      assert Discovery.extra_roots() == roots
    end
  end
end
