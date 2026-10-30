defmodule SuperPi.AI.ToolSchemas do
  @moduledoc """
  JSON Schema (`"type": "object"`) for the built-in tools, which are registered with a name and a
  description only. The providers send these as the tool's parameter schema.

  The Gemini client converts these to the upper-case dialect that Gemini wants.
  """

  @schema_keys ["parameters", :parameters, "input_schema", :input_schema, "inputSchema", :inputSchema]

  @doc """
  The parameter schema of a tool spec, under any of the keys in use (`parameters`, MCP
  `input_schema`/`inputSchema`), else the built-in schema for `name`.
  """
  @spec parameters(map(), String.t()) :: map()
  def parameters(spec, name) do
    Enum.find_value(@schema_keys, fn key ->
      case Map.get(spec, key) do
        %{} = schema when map_size(schema) > 0 -> schema
        _ -> nil
      end
    end) || for_tool(name)
  end

  @doc "The parameter schema for tool `name`. An unknown tool gets an empty object schema."
  @spec for_tool(String.t()) :: map()
  def for_tool("read") do
    obj(
      %{
        "path" => str("File path to read"),
        "offset" => int("First line to return (1-based)"),
        "limit" => int("Number of lines to return")
      },
      ["path"]
    )
  end

  def for_tool("write"), do: obj(%{"path" => str("File path to write"), "content" => str("Content to write")}, ["path", "content"])

  def for_tool("edit") do
    obj(
      %{
        "path" => str("File path to edit"),
        "old_text" => str("Exact text to replace. It must occur once."),
        "new_text" => str("Replacement text")
      },
      ["path", "old_text", "new_text"]
    )
  end

  def for_tool("bash"), do: obj(%{"command" => str("Shell command to run"), "cd" => str("Directory to run it in")}, ["command"])
  def for_tool("grep"), do: obj(%{"pattern" => str("Regular expression"), "path" => str("Directory to search")}, ["pattern"])
  def for_tool("find"), do: obj(%{"path" => str("Directory to search"), "pattern" => str("File name pattern, for example *.ex")}, [])
  def for_tool("ls"), do: obj(%{"path" => str("Directory to list")}, [])
  def for_tool("tool_search"), do: obj(%{"query" => str("Keyword to search the deferred tools")}, ["query"])
  def for_tool(_other), do: obj(%{}, [])

  defp obj(properties, required) do
    base = %{"type" => "object", "properties" => properties}
    if required == [], do: base, else: Map.put(base, "required", required)
  end

  defp str(description), do: %{"type" => "string", "description" => description}
  defp int(description), do: %{"type" => "integer", "description" => description}
end
