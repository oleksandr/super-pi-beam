defmodule SuperPi.CommandRulesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias SuperPi.CommandRules
  alias SuperPi.Plugins.Permissions

  @chain "git status --short --branch && git fetch origin && git log --oneline --max-count=5 HEAD && git log --oneline HEAD..origin/main"
  @prefixes [["git", "status"], ["git", "fetch"], ["git", "log"]]

  test "the requested Git chain is covered by all of its approved commands" do
    assert CommandRules.matches?(@chain, @prefixes)

    assert Permissions.command_allowed?(@chain, [
             "command(git status)",
             "command(git fetch)",
             "command(git log)"
           ])

    assert CommandRules.matches?(@chain, [["git", "log"]], [
             "command(git status)",
             "command(git fetch)"
           ])

    for missing <- @prefixes do
      refute CommandRules.matches?(@chain, @prefixes -- [missing])
    end
  end

  test "every position in a chain is checked and prefixes match whole words" do
    for command <- [
          "git push && git status",
          "git status && git push && git log",
          "git status && git push",
          "git status && git logfile",
          "git status && /usr/bin/git log",
          "git status && cd .. && git log"
        ] do
      refute CommandRules.matches?(command, @prefixes), command
    end

    assert CommandRules.matches?("git status&&git log", @prefixes)
    assert CommandRules.matches?(" \tgit status \t && \tgit log ", @prefixes)

    refute CommandRules.matches?("git status && git fetch other", [
             ["git", "status"],
             ["git", "fetch", "origin"]
           ])
  end

  test "quotes preserve argument boundaries, empty arguments and literal ampersands" do
    assert {:ok, [["git", "log", "--format=a && b", "", "HEAD"], ["git", "status"]]} =
             CommandRules.commands("git log --format='a && b' \"\" 'HE'AD && git status")

    assert {:ok, [["git", "log", "--format=a&b"], ["git", "status"]]} =
             CommandRules.commands("git log \"--format=a&b\" && git status")

    assert CommandRules.matches?("git log --format='a && b' && git status", @prefixes)
    refute CommandRules.matches?("'git log' && git status", @prefixes)
    refute CommandRules.matches?("git '' status && git log", @prefixes)
    assert :error = CommandRules.words("git log && git status")
  end

  test "unsupported shell syntax and malformed chains never inherit prefix approvals" do
    for command <- [
          "",
          " ",
          "&& git log",
          "git log &&",
          "git log && && git status",
          "git log &&& git status",
          "git log & git status",
          "git log &",
          "git log || git status",
          "git log; git status",
          "git log | git status",
          "git log > output",
          "git log 2>&1 && git status",
          "git log < input",
          "git log $(git status)",
          "git log `git status`",
          "git log $ARGS",
          "git log --format=\"$ARGS\" && git status",
          "git log && X=1 git status",
          "git log && git status\nother",
          "git log && git status\rmore",
          "git log \\ && git status",
          "git log && (git status)",
          "git log * && git status",
          "git log ? && git status",
          "git log {a,b} && git status",
          "git log ~/file && git status",
          "git log # comment && git status",
          "git log 'bad && git status",
          "git log \"bad && git status",
          "git log && ''",
          "git log && git status" <> <<0>>,
          "git log " <> <<255>>
        ] do
      refute CommandRules.matches?(command, @prefixes), command

      refute Permissions.command_allowed?(command, ["command(git log)", "command(git status)"]),
             command
    end
  end

  test "exact whole-command approvals are preserved without becoming script prefixes" do
    approved = "git log --oneline | head -5"
    rules = ["command(#{approved})"]
    assert Permissions.command_allowed?(approved, rules)
    refute Permissions.command_allowed?(approved <> " && git fetch origin", rules)
    refute CommandRules.matches?(approved <> " && git status", @prefixes, rules)
    refute Permissions.command_allowed?("git log", ["command(git log", "command()", 42])
    refute CommandRules.matches?(nil, @prefixes)
    refute CommandRules.matches?(@chain, nil)
  end

  test "deny rules apply to every segment, including commands spelled with quotes" do
    agent = %{"executionMode" => "accept-edits"}

    settings = %{
      "permissions" => %{"commandPrefixes" => @prefixes, "deny" => ["command(git fetch)"]}
    }

    for command <- [@chain, "git status && git f''etch origin", "git 'fetch' origin && git log"] do
      assert {:block, reason} =
               Permissions.evaluate("bash", %{"command" => command}, agent, settings)

      assert reason =~ "permissions.deny"
    end

    assert :allow =
             Permissions.evaluate(
               "bash",
               %{"command" => "git status && git log"},
               agent,
               settings
             )
  end

  test "Ask and Plan cannot execute an approved chain" do
    settings = %{"permissions" => %{"commandPrefixes" => @prefixes}}

    for mode <- ~w(ask plan) do
      assert {:block, _} =
               Permissions.evaluate(
                 "bash",
                 %{"command" => @chain},
                 %{"workflowMode" => mode},
                 settings
               )
    end

    assert :allow =
             Permissions.evaluate(
               "bash",
               %{"command" => @chain},
               %{"workflowMode" => "build"},
               settings
             )
  end

  property "removing any distinct command's approval prevents approval of the chain" do
    check all(
            commands <-
              uniq_list_of(string(:alphanumeric, min_length: 1, max_length: 12),
                min_length: 2,
                max_length: 8
              )
          ) do
      prefixes = Enum.map(commands, &["cmd_" <> &1])
      chain = Enum.map_join(prefixes, " && ", &(hd(&1) <> " --arg 'two words'"))
      assert CommandRules.matches?(chain, prefixes)
      for prefix <- prefixes, do: refute(CommandRules.matches?(chain, prefixes -- [prefix]))
    end
  end
end
