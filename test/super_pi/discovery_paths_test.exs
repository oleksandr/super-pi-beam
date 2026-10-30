defmodule SuperPi.DiscoveryPathsTest do
  use ExUnit.Case, async: false

  alias SuperPi.Discovery

  setup do
    keys = [:app_data_dir, :global_config_dir, :discovery_roots]
    saved = Enum.map(keys, &{&1, Application.fetch_env(:super_pi, &1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {k, {:ok, v}} -> Application.put_env(:super_pi, k, v)
        {k, :error} -> Application.delete_env(:super_pi, k)
      end)

      System.delete_env("SUPER_PI_DATA_DIR")
      System.delete_env("SUPER_PI_CONFIG_DIR")
      System.delete_env("SUPER_PI_DISCOVERY_ROOTS")
    end)

    Enum.each(keys, &Application.delete_env(:super_pi, &1))
    :ok
  end

  test "defaults follow the operating system and never name another tool's directory" do
    for dir <- [Discovery.default_app_data_dir(), Discovery.default_global_config_dir()] do
      assert dir =~ "super-pi"
      refute dir =~ ".gemini"
      refute dir =~ "antigravity"
    end
  end

  test "app env wins over the environment variable" do
    System.put_env("SUPER_PI_DATA_DIR", "/from/env")
    assert Discovery.default_app_data_dir() == "/from/env"

    Application.put_env(:super_pi, :app_data_dir, "/from/app")
    assert Discovery.default_app_data_dir() == "/from/app"
  end

  test "global config dir is configurable" do
    System.put_env("SUPER_PI_CONFIG_DIR", "/cfg")
    assert Discovery.default_global_config_dir() == "/cfg"
  end

  test "extra roots are scanned like the global config dir, after it" do
    tmp = Path.join(System.tmp_dir!(), "dp_#{System.unique_integer([:positive])}")
    global = Path.join(tmp, "global")
    extra = Path.join(tmp, "extra")
    File.mkdir_p!(Path.join([global, "skills", "a"]))
    File.mkdir_p!(Path.join([extra, "skills", "b"]))

    File.write!(
      Path.join([global, "skills", "a", "SKILL.md"]),
      "---\nname: a\ndescription: from global\n---\nbody"
    )

    File.write!(
      Path.join([extra, "skills", "b", "SKILL.md"]),
      "---\nname: b\ndescription: from extra\n---\nbody"
    )

    on_exit(fn -> File.rm_rf!(tmp) end)

    Application.put_env(:super_pi, :global_config_dir, global)
    Application.put_env(:super_pi, :discovery_roots, [extra])
    ws = Path.join(tmp, "ws")
    File.mkdir_p!(ws)

    names =
      Discovery.discover_skills([ws], app_data_dir: Path.join(tmp, "data")) |> Enum.map(& &1.name)

    assert "a" in names
    assert "b" in names
  end

  test "an explicit :global_config_dir option ignores extra roots" do
    Application.put_env(:super_pi, :discovery_roots, ["/should/not/be/used"])
    tmp = Path.join(System.tmp_dir!(), "dq_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    assert Discovery.discover_rule_files([tmp], global_config_dir: tmp) == []
  end
end
