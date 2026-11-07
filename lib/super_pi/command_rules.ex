defmodule SuperPi.CommandRules do
  @moduledoc "User-approved command prefixes, shared by conversations on this host."

  alias SuperPi.Discovery

  def path(agent) do
    Path.join(agent["appDataDir"] || Discovery.default_app_data_dir(), "command-rules.json")
  end

  def validate(prefixes) when is_list(prefixes) and length(prefixes) in 1..20 do
    if Enum.all?(prefixes, &valid_prefix?/1),
      do: {:ok, Enum.uniq(prefixes)},
      else:
        {:error,
         "Use command prefixes as lists of literal words, for example [\"git\", \"diff\"]."}
  end

  def validate(_), do: {:error, "Supply between 1 and 20 command prefixes."}

  defp valid_prefix?(words) when is_list(words) and length(words) in 1..20 do
    Enum.all?(words, fn word ->
      is_binary(word) and byte_size(word) in 1..256 and
        Regex.match?(~r/\A[a-zA-Z0-9_.,\/:@%+=-]+\z/, word)
    end) and not String.contains?(hd(words), "=") and not String.starts_with?(hd(words), "-")
  end

  defp valid_prefix?(_), do: false

  @doc "Parses a single literal command; compound commands are not valid prefix rules."
  def words(command) do
    case commands(command) do
      {:ok, [words]} -> {:ok, words}
      _ -> :error
    end
  end

  @doc """
  Parses literal argv lists separated by unquoted `&&`. Every segment must be nonempty.
  Other shell syntax, expansions, escapes and redirects require approval of the whole command.
  This parser never executes a shell. Quotes preserve literal words, including quoted `&&`.
  """
  def commands(command) when is_binary(command) do
    if String.contains?(command, [
         "$",
         "`",
         "|",
         ";",
         "<",
         ">",
         "\n",
         "\r",
         "\\",
         "*",
         "?",
         "[",
         "]",
         "{",
         "}",
         "(",
         ")",
         "~",
         "#",
         <<0>>
       ]) do
      :error
    else
      scan(command, :bare, nil, [], [])
    end
  end

  def commands(_), do: :error

  defp scan("", :bare, word, words, segments) do
    with {:ok, argv} <- finish_command(word, words),
         do: {:ok, Enum.reverse([argv | segments])}
  end

  defp scan("", _quote, _word, _words, _segments), do: :error

  defp scan("&&" <> rest, :bare, word, words, segments) do
    with {:ok, argv} <- finish_command(word, words),
         do: scan(rest, :bare, nil, [], [argv | segments])
  end

  defp scan("&" <> _, :bare, _word, _words, _segments), do: :error

  defp scan(<<space, rest::binary>>, :bare, word, words, segments) when space in [32, 9],
    do: scan(rest, :bare, nil, finish_word(word, words), segments)

  defp scan(<<quote, rest::binary>>, :bare, word, words, segments) when quote in [?', ?"],
    do: scan(rest, quote, word || "", words, segments)

  defp scan(<<quote, rest::binary>>, quote, word, words, segments),
    do: scan(rest, :bare, word, words, segments)

  defp scan(<<char::utf8, rest::binary>>, quote, word, words, segments)
       when char >= 32 or char == 9,
       do: scan(rest, quote, (word || "") <> <<char::utf8>>, words, segments)

  defp scan(_, _, _, _, _), do: :error

  defp finish_word(nil, words), do: words
  defp finish_word(word, words), do: [word | words]

  defp finish_command(word, words) do
    case Enum.reverse(finish_word(word, words)) do
      [first | _] = argv when first != "" ->
        if String.contains?(first, "="), do: :error, else: {:ok, argv}

      _ ->
        :error
    end
  end

  @doc "Every command in a literal && chain must have an approved prefix or legacy rule."
  def matches?(command, prefixes, allow_rules \\ [])

  def matches?(command, prefixes, allow_rules)
      when is_binary(command) and is_list(prefixes) and is_list(allow_rules) do
    patterns = Enum.flat_map(allow_rules, &legacy_pattern/1)

    # An explicitly approved complete command may contain shell syntax. It never becomes a
    # prefix for a longer script, and complex rules are never spliced into a composed approval.
    if String.trim(command) in patterns do
      true
    else
      legacy_prefixes = for pattern <- patterns, {:ok, argv} <- [words(pattern)], do: argv

      case commands(command) do
        {:ok, segments} ->
          Enum.all?(segments, fn argv ->
            matches_argv?(argv, prefixes) or
              Enum.any?(legacy_prefixes, &List.starts_with?(argv, &1))
          end)

        :error ->
          false
      end
    end
  end

  def matches?(_, _, _), do: false

  defp legacy_pattern("command(" <> rest) do
    if String.ends_with?(rest, ")"),
      do: [binary_part(rest, 0, byte_size(rest) - 1)],
      else: []
  end

  defp legacy_pattern(_), do: []

  def matches_argv?(words, prefixes) when is_list(words) and is_list(prefixes),
    do: Enum.any?(prefixes, &(valid_prefix?(&1) and List.starts_with?(words, &1)))

  def matches_argv?(_, _), do: false

  def load(agent) do
    case read(path(agent)) do
      {:ok, rules} -> rules
      {:error, _} -> []
    end
  end

  def save(agent, prefixes) do
    with {:ok, prefixes} <- validate(prefixes) do
      file = path(agent)
      lock = file <> ".lock"

      # An atomic directory lock also serializes separate Zed and CLI BEAM processes.
      with :ok <- File.mkdir_p(Path.dirname(file)),
           :ok <- acquire_lock(lock, 100) do
        try do
          with {:ok, current} <- read(file) do
            atomic_write(file, Enum.uniq(current ++ prefixes))
          end
        after
          File.rmdir(lock)
        end
      end
    end
  end

  defp acquire_lock(path, 0),
    do:
      {:error,
       "Command rules are busy. If no Super-Pi process is saving rules, remove the stale lock directory #{path}."}

  defp acquire_lock(path, attempts) do
    case File.mkdir(path) do
      :ok ->
        :ok

      {:error, :eexist} ->
        Process.sleep(10)
        acquire_lock(path, attempts - 1)

      {:error, reason} ->
        {:error, "Cannot lock command rules: #{inspect(reason)}"}
    end
  end

  defp read(file) do
    case File.read(file) do
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, "Cannot read command rules: #{inspect(reason)}"}
      {:ok, data} -> decode(data)
    end
  end

  defp decode(data) do
    with {:ok, %{"version" => 1, "allow" => rules}} when is_list(rules) <- Jason.decode(data),
         true <- Enum.all?(rules, &valid_prefix?/1) do
      {:ok, rules}
    else
      _ -> {:error, "Invalid command-rules.json; existing rules were not changed."}
    end
  end

  defp atomic_write(file, rules) do
    temp = file <> ".#{System.unique_integer([:positive])}.tmp"

    try do
      with :ok <-
             File.write(
               temp,
               Jason.encode!(%{"version" => 1, "allow" => rules}, pretty: true) <> "\n",
               [:exclusive, :sync]
             ),
           :ok <- File.chmod(temp, 0o600),
           :ok <- File.rename(temp, file) do
        :ok
      else
        {:error, reason} -> {:error, "Cannot save command rules: #{inspect(reason)}"}
      end
    after
      File.rm(temp)
    end
  end
end
