defmodule SuperPi.PluginTools do
  @moduledoc """
  Trusted tool declarations from the extensions composed by a harness. Specs are data; handlers
  remain in their owning plugin. `toolProviders` is server-owned and stripped from remote input.
  Administrative status is read from the trusted declaration, never from client-supplied specs.
  """

  def declare(extensions, agent) do
    previous_names = agent["pluginToolNames"] || []

    providers =
      for ext <- extensions,
          mod = module(ext),
          Code.ensure_loaded?(mod),
          function_exported?(mod, :tools, 1),
          mod.tools(agent) != [],
          do: Atom.to_string(mod)

    agent = Map.put(agent, "toolProviders", Enum.uniq(providers))
    specs = Enum.flat_map(modules(agent), & &1.tools(agent))
    names = Enum.map(specs, & &1["name"])

    if length(names) != length(Enum.uniq(names)),
      do: raise(ArgumentError, "Duplicate plugin tool declaration")

    agent
    |> Map.put("pluginToolNames", names)
    |> Map.put(
      "tools",
      Enum.reject(agent["tools"] || [], &(&1["name"] in (names ++ previous_names))) ++ specs
    )
  end

  def declaration(name, agent) do
    Enum.find_value(modules(agent), fn mod ->
      case Enum.find(mod.tools(agent), &(&1["name"] == name)) do
        nil -> nil
        spec -> {mod, spec}
      end
    end)
  end

  def administrative?(name, agent) do
    case declaration(name, agent) do
      {_, spec} -> spec["administrative"] == true
      nil -> false
    end
  end

  def policy(name, args, agent) do
    case declaration(name, agent) do
      {mod, spec} ->
        with {:ok, policy} <- mod.tool_policy(name, args, agent),
             do: {:ok, Map.put(policy, :administrative, spec["administrative"] == true)}

      nil ->
        {:ok, %{}}
    end
  end

  def execute(name, args, ctx) do
    case declaration(name, agent(ctx)) do
      {mod, _spec} -> mod.execute_tool(name, args, ctx)
      nil -> :unhandled
    end
  end

  def agent(ctx) do
    case ctx[:conversation_id] do
      id when is_integer(id) ->
        SuperPi.Durable.Doc.snapshot("conversation", id, "pi.agent") || %{}

      _ ->
        ctx[:agent] || %{}
    end
  end

  defp modules(agent) do
    for name <- agent["toolProviders"] || [],
        mod = existing_module(name),
        mod && Code.ensure_loaded?(mod) && function_exported?(mod, :tools, 1),
        do: mod
  end

  defp existing_module(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end

  defp module({mod, _}), do: mod
  defp module(mod), do: mod
end
