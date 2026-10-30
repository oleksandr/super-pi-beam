defmodule SuperPi.Harness.Defaults do
  @moduledoc """
  Builds the `pi.agent` defaults of a harness declared with `use SuperPi.Harness`.

  Each setting resolves in one order: the caller's `opts`, then the harness declaration, then the
  application environment, then a fallback.

  | Setting | opts | Application environment | Fallback |
  |---|---|---|---|
  | model | `:model` | `config :super_pi, :default_model` | `#{inspect("gemini-3-flash-preview")}` |
  | effort | `:effort` | | `"medium"` |
  | executionMode | `:mode` | | `"accept-edits"` |
  | workspacePaths | `:workspace_paths` | `:workspace_paths` (`:knowledge_paths` for `workspace: :knowledge_paths`) | working directory |
  | systemSections | `:system_sections` | | the declared `prompt` |

  The tool loadout is `:all`, `{:only, names}` or `{:except, names}`, resolved against
  `SuperPi.Tools.active_llm_tools/0`.
  """

  alias SuperPi.Discovery
  alias SuperPi.Tools

  @fallback_model "gemini-3-flash-preview"

  @doc "Model for a harness that does not name one. Set it with `config :super_pi, :default_model`."
  @spec default_model() :: String.t()
  def default_model, do: Application.get_env(:super_pi, :default_model) || @fallback_model

  @doc """
  Options for `SuperPi.Plugins.JevRouter` from `config :super_pi, :planning_model` and
  `:implementation_model`. A model that is not configured is left out, so the router keeps its own
  fallback.
  """
  @spec model_route() :: keyword()
  def model_route do
    for key <- [:planning_model, :implementation_model],
        model = Application.get_env(:super_pi, key),
        is_binary(model),
        do: {key, model}
  end

  @doc "Builds the `pi.agent` map for `module` (a module that used `SuperPi.Harness`)."
  @spec build(module(), keyword()) :: map()
  def build(module, opts \\ []) do
    spec = module.__harness__()

    base = %{
      "model" => opts[:model] || spec[:model] || default_model(),
      "effort" => opts[:effort] || spec[:effort] || "medium",
      "executionMode" => opts[:mode] || spec[:mode] || "accept-edits",
      "maxExecutionMode" => spec[:max_mode] || spec[:mode] || "accept-edits",
      "workspacePaths" => opts[:workspace_paths] || workspace_paths(spec[:workspace]),
      "tools" => resolve_tools(spec[:tools] || :all),
      "systemSections" => sections(opts[:system_sections], spec[:prompt], module)
    }

    case workspace_config(spec[:workspace]) do
      nil -> base
      ws -> Map.put(base, "workspace", ws)
    end
  end

  @doc """
  Machine-readable summary of `module`, derived from its declaration. `"plugins"` lists plugin ids
  in load order; `"tools"` is `"all"`, `%{"only" => names}` or `%{"except" => names}`;
  `"workspace"` is the workspace kind; `"network"` is `false` when the workspace turns off the
  `:net` capability.
  """
  @spec capabilities(module()) :: map()
  def capabilities(module) do
    spec = module.__harness__()
    workspace = workspace_config(spec[:workspace]) || %{"kind" => "local"}

    %{
      "id" => module.id(),
      "name" => module.name(),
      "description" => module.description(),
      "plugins" => Enum.map(module.extensions([]), &plugin_id/1),
      "tools" => tools_summary(spec[:tools] || :all),
      "workspace" => workspace["kind"],
      "network" => workspace["network"] != false,
      "effort" => spec[:effort] || "medium",
      "mode" => spec[:mode] || "accept-edits",
      "maxMode" => spec[:max_mode] || spec[:mode] || "accept-edits"
    }
  end

  defp plugin_id({mod, _opts}), do: plugin_id(mod)

  defp plugin_id(mod) do
    Code.ensure_loaded(mod)
    if function_exported?(mod, :id, 0), do: mod.id(), else: inspect(mod)
  end

  defp tools_summary(:all), do: "all"
  defp tools_summary({:only, names}), do: %{"only" => names}
  defp tools_summary({:except, names}), do: %{"except" => names}

  @doc "Resolves a tool loadout against the tool catalog."
  @spec resolve_tools(:all | {:only, [String.t()]} | {:except, [String.t()]}) :: [map()]
  def resolve_tools(:all), do: Tools.active_llm_tools()

  def resolve_tools({:only, names}),
    do: Enum.filter(Tools.active_llm_tools(), &(&1["name"] in names))

  def resolve_tools({:except, names}),
    do: Enum.reject(Tools.active_llm_tools(), &(&1["name"] in names))

  defp sections([_ | _] = custom, _prompt, _module), do: custom
  defp sections(_, prompt, module), do: [%{"id" => "core", "content" => prompt || module.name()}]

  defp workspace_paths(:knowledge_paths), do: Discovery.default_knowledge_paths()
  defp workspace_paths(_), do: Discovery.default_workspace_paths()

  defp workspace_config(%{} = cfg), do: cfg
  defp workspace_config(_), do: nil
end
