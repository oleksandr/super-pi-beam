defmodule SuperPi.PluginsTest do
  use ExUnit.Case, async: true

  alias SuperPi.Plugins
  alias SuperPi.Plugins.{AutoCommit, ConfirmDestructive, GitCheckpoint}

  describe "Plugin Registry & Resolution" do
    test "lists all built-in plugins" do
      plugins = Plugins.list()
      assert GitCheckpoint in plugins
      assert AutoCommit in plugins
      assert ConfirmDestructive in plugins
    end

    test "resolves plugins by atom and string name" do
      assert Plugins.resolve(:git_checkpoint) == GitCheckpoint
      assert Plugins.resolve("git-checkpoint") == GitCheckpoint
      assert Plugins.resolve("auto_commit") == AutoCommit
      assert Plugins.resolve("confirm_destructive") == ConfirmDestructive
      assert Plugins.resolve("unknown") == nil
    end
  end

  describe "ConfirmDestructive Plugin" do
    test "allows safe bash commands" do
      assert ConfirmDestructive.before_tool("bash", %{"command" => "ls -la"}, %{}) == :allow
      assert ConfirmDestructive.before_tool("bash", %{"command" => "git status"}, %{}) == :allow
      assert ConfirmDestructive.before_tool("read", %{"path" => "README.md"}, %{}) == :allow
    end

    test "blocks dangerous rm -rf, git reset --hard, and DROP TABLE" do
      assert {:block, msg1} = ConfirmDestructive.before_tool("bash", %{"command" => "rm -rf /tmp/test"}, %{})
      assert msg1 =~ "Destructive operation intercepted"

      assert {:block, msg2} = ConfirmDestructive.before_tool("bash", %{"command" => "git reset --hard HEAD~1"}, %{})
      assert msg2 =~ "Destructive operation intercepted"

      assert {:block, msg3} = ConfirmDestructive.before_tool("bash", %{"command" => "psql -c 'DROP TABLE users'"}, %{})
      assert msg3 =~ "Destructive operation intercepted"
    end
  end

  describe "GitCheckpoint Plugin" do
    test "implements before_tool pass-through safely" do
      assert GitCheckpoint.before_tool("read", %{}, %{}) == :allow
      assert GitCheckpoint.before_tool("write", %{"path" => "foo.txt"}, %{}) == :allow
    end
  end

  describe "AutoCommit Plugin" do
    test "implements after_run and returns :accept" do
      tmp_ws = Path.join(System.tmp_dir!(), "auto_commit_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_ws)
      System.cmd("git", ["init"], cd: tmp_ws)
      File.write!(Path.join(tmp_ws, "test.txt"), "test")
      assert AutoCommit.after_run(%{last_assistant_text: "Test auto commit"}, %{workspace_root: tmp_ws}) == :accept
    end
  end
end
