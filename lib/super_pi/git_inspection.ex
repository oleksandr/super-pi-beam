defmodule SuperPi.GitInspection do
  @moduledoc "Read-only Git inspection with literal arguments and disabled external helpers."

  @common ~w(--no-pager --no-optional-locks -c core.fsmonitor=false -c core.untrackedCache=false -c log.showSignature=false)
  @status ~w(-s --short -b --branch --show-stash --porcelain -z --null --ignored --untracked-files)
  @diff ~w(-p --patch --stat --numstat --shortstat --name-only --name-status --summary --cached --staged --check --raw --no-renames --no-color --color=never --word-diff --word-diff=plain --word-diff=porcelain --ignore-space-change --ignore-all-space --ignore-blank-lines)
  @log ~w(--oneline --stat --numstat --shortstat --name-only --name-status --summary --graph --decorate --no-decorate --all --branches --tags --remotes --first-parent --no-merges --merges --reverse --date-order --topo-order --follow -p --patch --no-color --color=never)

  def spec do
    %{
      "name" => "git_inspect",
      "description" =>
        "Inspect Git status, log or diff without edits or shell execution. Use in Plan for code review. Command-prefix approvals apply (git status, git log, git diff); request_command_approval can approve all three together. Only read-only flags are supported; external diff/textconv helpers and pagers are disabled.",
      "effects" => ["read"],
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "operation" => %{"type" => "string", "enum" => ["status", "log", "diff"]},
          "args" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" =>
              "Literal arguments, e.g. [\"--oneline\", \"-n\", \"20\"] or [\"main...HEAD\", \"--stat\"]. No shell syntax."
          },
          "cd" => %{
            "type" => "string",
            "description" => "Repository directory (defaults to workspace)"
          }
        },
        "required" => ["operation"]
      }
    }
  end

  def argv(args) do
    operation = args["operation"]
    words = Map.get(args, "args", [])

    if operation in ["status", "log", "diff"] and is_list(words) and length(words) <= 100 and
         Enum.all?(
           words,
           &(is_binary(&1) and byte_size(&1) <= 4096 and
               not String.contains?(&1, [<<0>>, "\n", "\r"]))
         ) and
         valid_args?(operation, words) do
      {:ok, ["git", operation | words]}
    else
      {:error,
       "git_inspect supports only read-only status/log/diff arguments. No output files, external helpers, shell syntax or --no-index."}
    end
  end

  def command(args) do
    case argv(args) do
      {:ok, words} -> Enum.map_join(words, " ", &quote_word/1)
      {:error, _} -> "git_inspect (invalid arguments)"
    end
  end

  def execute(args, env, cd) do
    with {:ok, ["git", operation | words]} <- argv(args) do
      protections = if operation == "status", do: [], else: ["--no-ext-diff", "--no-textconv"]

      case env.exec_command("git", @common ++ [operation] ++ protections ++ words, cd: cd) do
        {:ok, %{exit_code: code, output: output, spilled_path: spilled}} ->
          %{
            "is_error" => code != 0,
            "output" => output,
            "structured_output" => %{"exit_code" => code},
            "details" => %{"spilled_path" => spilled}
          }

        {:error, reason} ->
          error(inspect(reason))
      end
    else
      {:error, reason} -> error(reason)
    end
  end

  defp valid_args?(_, []), do: true
  defp valid_args?(_, ["--" | paths]), do: Enum.all?(paths, &safe_path?/1)

  defp valid_args?("log", [flag, n | rest]) when flag in ["-n", "--max-count", "--skip"] do
    Regex.match?(~r/\A\d+\z/, n) and valid_args?("log", rest)
  end

  defp valid_args?(operation, [arg | rest]) do
    allowed =
      case operation do
        "status" ->
          arg in @status or
            Regex.match?(
              ~r/\A(?:--porcelain=(?:v?[12])|--untracked-files=(?:no|normal|all)|--ignored=(?:traditional|matching|no)|-u(?:no|normal|all))\z/,
              arg
            )

        "diff" ->
          arg in @diff or Regex.match?(~r/\A(?:-U\d+|--unified=\d+)\z/, arg) or revision?(arg)

        "log" ->
          arg in @log or
            Regex.match?(
              ~r/\A(?:-\d+|--(?:max-count|skip)=\d+|--(?:format|pretty|since|until|author|grep)=.+)\z/,
              arg
            ) or revision?(arg)
      end

    allowed and valid_args?(operation, rest)
  end

  defp revision?(arg), do: Regex.match?(~r/\A[a-zA-Z0-9_][a-zA-Z0-9_.\/@^~:-]*\z/, arg)

  defp safe_path?(path),
    do:
      path != "" and Path.type(path) == :relative and not String.starts_with?(path, ":") and
        ".." not in Path.split(path)

  defp quote_word(word),
    do:
      if(Regex.match?(~r/\A[a-zA-Z0-9_.,\/:@%+=^-]+\z/, word),
        do: word,
        else: "'" <> String.replace(word, "'", "'\\''") <> "'"
      )

  defp error(message), do: %{"is_error" => true, "output" => message, "details" => %{}}
end
