defmodule SuperPi.Plugins.Profiles.Definition do
  @moduledoc "Normalizes profile maps and reads the supported agent Markdown front-matter subset."
  alias SuperPi.ExecutionMode

  def normalize(profile) when is_map(profile) do
    p = Map.new(profile, fn {k, v} -> {to_string(k), v} end)
    id = p["id"]
    mode = ExecutionMode.normalize(p["execution_mode"] || "plan")
    tools = tool_filter(p["tools"] || "all")

    if (is_binary(id) and Regex.match?(~r/\A[a-zA-Z0-9_-]+\z/, id) and mode) && tools &&
         Enum.all?(
           ["name", "description", "prompt", "model", "effort"],
           &(is_nil(p[&1]) or is_binary(p[&1]))
         ) do
      Map.merge(Map.take(p, ["model", "effort", "source"]), %{
        "id" => id,
        "name" => p["name"] || id,
        "description" => p["description"] || "",
        "execution_mode" => mode,
        "tools" => tools,
        "prompt" => p["prompt"] || ""
      })
    end
  end

  def normalize(_), do: nil

  defp tool_filter(value) when value in [:all, "all"], do: "all"

  defp tool_filter({kind, names}) when kind in [:only, :except],
    do: tool_filter(%{to_string(kind) => names})

  defp tool_filter(%{"only" => names}), do: names_filter("only", names)
  defp tool_filter(%{"except" => names}), do: names_filter("except", names)
  defp tool_filter(names) when is_list(names), do: names_filter("only", names)
  defp tool_filter(_), do: nil

  defp names_filter(kind, names) do
    if is_list(names) and Enum.all?(names, &is_binary/1),
      do: %{kind => Enum.map(names, &tool_name/1)}
  end

  defp tool_name(name) do
    case String.downcase(name) do
      "glob" -> "find"
      known when known in ~w(read grep find ls write edit bash) -> known
      _ -> name
    end
  end

  def read(path) do
    with {:ok, text} <- File.read(path),
         [_, header, body] <-
           Regex.run(~r/\A\x{FEFF}?---\r?\n(.*?)\r?\n---\s*\r?\n(.*)\z/su, text),
         {:ok, fields} <- parse_header(header),
         true <- Map.get(fields, "mode", "primary") in ["primary", "all"],
         {:ok, tools} <- markdown_tools(fields["tools"]) do
      normalize(%{
        "id" => Path.basename(path, ".md"),
        "name" => fields["name"],
        "description" => fields["description"],
        "model" => fields["model"],
        "effort" => fields["effort"],
        "execution_mode" => fields["execution_mode"] || "plan",
        "tools" => tools,
        "prompt" => String.trim(body),
        "source" => path
      })
    else
      _ -> nil
    end
  end

  # Deliberately a common subset, not a YAML evaluator. No tags, aliases or executable values.
  defp parse_header(header) do
    lines = String.split(header, "\n")

    lines
    |> Enum.reduce_while({%{}, nil}, fn line, {fields, key} ->
      cond do
        String.trim(line) == "" or String.starts_with?(String.trim(line), "#") ->
          {:cont, {fields, key}}

        Regex.match?(~r/\A[\w-]+:/, line) ->
          [name, value] = String.split(line, ":", parts: 2)

          if Map.has_key?(fields, name),
            do: {:halt, :error},
            else: {:cont, {Map.put(fields, name, String.trim(value)), name}}

        key && String.starts_with?(line, [" ", "\t"]) ->
          {:cont, {Map.update!(fields, key, &(&1 <> "\n" <> String.trim(line))), key}}

        true ->
          {:halt, :error}
      end
    end)
    |> case do
      {fields, _} -> {:ok, Map.new(fields, fn {k, v} -> {k, scalar(v)} end)}
      _ -> :error
    end
  end

  defp scalar(value) do
    value = String.trim(value)

    cond do
      String.starts_with?(value, ["|\n", ">\n", "|-\n", ">-\n"]) ->
        value |> String.split("\n") |> tl() |> Enum.join(" ")

      Regex.match?(~r/\A(["']).*\1\z/s, value) ->
        String.slice(value, 1, String.length(value) - 2)

      true ->
        value
    end
  end

  defp markdown_tools(nil), do: {:ok, "all"}

  defp markdown_tools(value) do
    value = String.trim(value)

    cond do
      value == "" ->
        :error

      String.contains?(value, ":") ->
        entries = String.split(value, "\n", trim: true)
        pairs = Enum.map(entries, &Regex.run(~r/\A([\w*-]+):\s*(true|false)\z/, &1))

        if Enum.all?(pairs, &is_list/1) do
          yes = for [_, name, "true"] <- pairs, do: tool_name(name)
          no = for [_, name, "false"] <- pairs, do: tool_name(name)

          cond do
            "*" in no -> {:ok, %{"only" => yes -- ["*"]}}
            yes != [] and "*" not in yes -> {:ok, %{"only" => yes -- no}}
            true -> {:ok, %{"except" => no}}
          end
        else
          :error
        end

      true ->
        names =
          value
          |> String.trim_leading("[")
          |> String.trim_trailing("]")
          |> String.split(~r/[,\n]/, trim: true)
          |> Enum.map(&scalar(String.trim_leading(String.trim(&1), "- ")))

        if Enum.all?(names, &Regex.match?(~r/\A[\w*-]+\z/, &1)),
          do: {:ok, %{"only" => Enum.map(names, &tool_name/1)}},
          else: :error
    end
  end
end
