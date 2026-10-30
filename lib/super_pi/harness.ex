defmodule SuperPi.Harness do
  @moduledoc """
  Pluggable agent harness specification and registry (`REQ-HARNESS-01`).

  A harness is a named persona: a plugin set plus `pi.agent` defaults. Three showcase harnesses
  and one safety harness ship with Super-Pi-BEAM:

  | Id | Module | Distinct because |
  |---|---|---|
  | `super-pi-code` | `SuperPi.Harness.Code` | Mutates a repository, reversibly (checkpoints, optional auto-commit). |
  | `super-pi-assistant` | `SuperPi.Harness.Assistant` | Works with a human present, reaches the web and third-party services over MCP, has no filesystem. |
  | `super-pi-librarian` | `SuperPi.Harness.Librarian` | Runs with no human present (scheduler) and remembers across sessions (memory). |
  | `super-pi-planner` | `SuperPi.Harness.Planner` | Cannot write. |

  The ids of earlier releases (`super-pi-agent`, `-fast`, `-workspace`, `-auto`, `-interactive`) still
  resolve, to `Code` or `Assistant`, but `list/0` no longer shows them.

  ## Declaring a harness

      defmodule MyApp.Harness.Triage do
        alias SuperPi.Plugins

        use SuperPi.Harness,
          id: "my-triage",
          name: "Triage",
          description: "Sorts incoming tickets",
          effort: "low",
          mode: "accept-edits",
          max_mode: "accept-edits",
          workspace: %{"kind" => "none"},
          tools: {:only, ["todo"]},
          prompt: "You triage tickets.",
          plugins: [Plugins.Todo, Plugins.Permissions]
      end

  The macro defines `id/0`, `name/0`, `description/0`, `capabilities/0`, `extensions/1` and
  `agent_defaults/1`, all overridable. Register the module with
  `config :super_pi, extra_harnesses: [MyApp.Harness.Triage]`.

  | Option | Meaning |
  |---|---|
  | `:id`, `:name`, `:description` | Required. Metadata for model listings and discovery. |
  | `:plugins` | Plugin specs (`Module` or `{Module, opts}`). Order matters for `before_compact`: the first plugin that does not answer `:default` ends the chain. |
  | `:effort`, `:mode`, `:model` | Defaults for `pi.agent`. See `SuperPi.Harness.Defaults`. |
  | `:max_mode` | Highest `executionMode` the harness allows (`"plan"`, `"accept-edits"` or `"auto"`). `Permissions` enforces it. Defaults to `:mode`. |
  | `:workspace` | `:local` (default), `:knowledge_paths` or a `"workspace"` map such as `%{"kind" => "none"}`. |
  | `:tools` | `:all`, `{:only, names}` or `{:except, names}`. |
  | `:prompt` | Core system prompt. |
  """

  @doc "Unique string identifier for the harness (e.g., 'super-pi-code')"
  @callback id() :: String.t()

  @doc "Human-readable name"
  @callback name() :: String.t()

  @doc "Short description for model listings and discovery"
  @callback description() :: String.t()

  @doc "List of SuperPi.Extension modules active in this harness"
  @callback extensions(opts :: keyword()) :: list(module() | {module(), term()})

  @doc "Default document configuration for the conversation agent"
  @callback agent_defaults(opts :: keyword()) :: map()

  @doc """
  Machine-readable summary of the harness: id, plugins, tool loadout, workspace kind and modes.
  Interfaces that must describe a harness to a client (ACP `initialize`, `workspace.metadata`,
  `GET /v1/models`) call it through `capabilities/1`, which tolerates harnesses without it.
  """
  @callback capabilities() :: map()

  @optional_callbacks capabilities: 0

  @doc """
  Capability summary of `harness`. A harness without `capabilities/0` gets one built from its
  metadata, so external `:extra_harnesses` modules keep working.
  """
  @spec capabilities(module()) :: map()
  def capabilities(harness) do
    Code.ensure_loaded(harness)

    if function_exported?(harness, :capabilities, 0) do
      harness.capabilities()
    else
      %{"id" => harness.id(), "name" => harness.name(), "description" => harness.description()}
    end
  end

  @doc false
  defmacro __using__(opts) do
    quote do: use(SuperPi.Harness.DSL, unquote(opts))
  end

  @registry %{
    "code" => SuperPi.Harness.Code,
    "super-pi-code" => SuperPi.Harness.Code,
    "assistant" => SuperPi.Harness.Assistant,
    "super-pi-assistant" => SuperPi.Harness.Assistant,
    "librarian" => SuperPi.Harness.Librarian,
    "super-pi-librarian" => SuperPi.Harness.Librarian,
    "planner" => SuperPi.Harness.Planner,
    "plan" => SuperPi.Harness.Planner,
    "super-pi-planner" => SuperPi.Harness.Planner,
    # Ids of earlier releases. They resolve but are not listed (`list/0`).
    "workspace" => SuperPi.Harness.Code,
    "super-pi-workspace" => SuperPi.Harness.Code,
    "auto" => SuperPi.Harness.Code,
    "super-pi-auto" => SuperPi.Harness.Code,
    "default" => SuperPi.Harness.Assistant,
    "super-pi" => SuperPi.Harness.Assistant,
    "super-pi-agent" => SuperPi.Harness.Assistant,
    "fast" => SuperPi.Harness.Assistant,
    "super-pi-fast" => SuperPi.Harness.Assistant,
    "interactive" => SuperPi.Harness.Assistant,
    "super-pi-interactive" => SuperPi.Harness.Assistant
  }

  # Modules of earlier releases, kept as shims. A client may pin a module name.
  @shims %{
    SuperPi.Harness.Default => SuperPi.Harness.Assistant,
    SuperPi.Harness.Fast => SuperPi.Harness.Assistant,
    SuperPi.Harness.Interactive => SuperPi.Harness.Assistant,
    SuperPi.Harness.Workspace => SuperPi.Harness.Code,
    SuperPi.Harness.Autonomous => SuperPi.Harness.Code
  }

  @builtin_harnesses [
    SuperPi.Harness.Code,
    SuperPi.Harness.Assistant,
    SuperPi.Harness.Librarian,
    SuperPi.Harness.Planner
  ]

  @doc """
  Lists the harness modules to show to users: the four built-in ones and any configured via
  `:extra_harnesses`. Resolution (`resolve/1`, `harness?/1`) is wider than this list: it also
  accepts the ids of earlier releases.
  """
  def list do
    extra = Application.get_env(:super_pi, :extra_harnesses, [])
    Enum.uniq(@builtin_harnesses ++ extra)
  end

  @doc """
  Returns true if the given model name or ID corresponds to a registered harness.
  """
  def harness?(module) when is_atom(module) do
    extra = Application.get_env(:super_pi, :extra_harnesses, [])

    (Code.ensure_loaded?(module) and function_exported?(module, :id, 0)) or
      Map.has_key?(@registry, to_string(module)) or
      Enum.member?(extra, module)
  end

  def harness?(name_or_id) when is_binary(name_or_id) do
    key =
      name_or_id
      |> String.downcase()
      |> String.replace_prefix("super-pi/", "")

    extra = Application.get_env(:super_pi, :extra_harnesses, [])

    Map.has_key?(@registry, key) or
      Enum.any?(extra, fn mod ->
        function_exported?(mod, :id, 0) and mod.id() == key
      end) or
      match_module_string?(name_or_id)
  end

  def harness?(_), do: false

  @doc """
  Resolves a model name, alias, module, or harness ID to its corresponding Harness module.
  Falls back to `default/0` if unknown.
  """
  def resolve(module) when is_atom(module) do
    cond do
      Map.has_key?(@shims, module) -> Map.fetch!(@shims, module)
      Code.ensure_loaded?(module) and function_exported?(module, :id, 0) -> module
      true -> Map.get(@registry, to_string(module), default())
    end
  end

  def resolve(name_or_id) when is_binary(name_or_id) do
    key =
      name_or_id
      |> String.downcase()
      |> String.replace_prefix("super-pi/", "")

    extra = Application.get_env(:super_pi, :extra_harnesses, [])

    extra_match =
      Enum.find(extra, fn mod ->
        function_exported?(mod, :id, 0) and (mod.id() == key or mod.id() == name_or_id)
      end)

    cond do
      extra_match != nil ->
        extra_match

      Map.has_key?(@registry, key) ->
        Map.get(@registry, key)

      true ->
        resolve_module_string(name_or_id) || default()
    end
  end

  def resolve(_), do: default()

  @doc """
  Extensions of `harness` for a caller that is not the local user (Gateway, RPC, MCP, subagents).

  `InlineBash` runs `!{...}` shell commands from user input with no permission check, so a
  remote caller must not get it. No built-in harness carries it, but a harness from `:extra_harnesses` may. Use this instead of `harness.extensions([])` on those paths.
  """
  @spec remote_extensions(module()) :: [module() | {module(), keyword()}]
  def remote_extensions(harness) when is_atom(harness) do
    Enum.reject(harness.extensions([]), fn
      SuperPi.Plugins.InlineBash -> true
      {SuperPi.Plugins.InlineBash, _} -> true
      _ -> false
    end)
  end

  @doc """
  Default harness for entry points that receive no harness name (Gateway, RPC, MCP, CLI).

  Configure it with `config :super_pi, default_harness: "<harness id>"`. The default is
  `super-pi-code`, which carries the permission and safety plugins.
  """
  @spec default() :: module()
  def default do
    id = Application.get_env(:super_pi, :default_harness, "super-pi-code")

    case fetch(id) do
      {:ok, mod} -> mod
      {:error, _} -> SuperPi.Harness.Code
    end
  end

  @doc """
  Strict form of `resolve/1`. An unknown name is an error, not a silent default.

  A deployment that wants a fallback can set `config :super_pi, fallback_harness: "<id>"`.
  """
  @spec fetch(String.t() | module()) :: {:ok, module()} | {:error, {:unknown_harness, term()}}
  def fetch(name) do
    cond do
      harness?(name) ->
        {:ok, resolve(name)}

      fallback = Application.get_env(:super_pi, :fallback_harness) ->
        if harness?(fallback),
          do: {:ok, resolve(fallback)},
          else: {:error, {:unknown_harness, name}}

      true ->
        {:error, {:unknown_harness, name}}
    end
  end

  defp match_module_string?(str), do: resolve_module_string(str) != nil

  # The harness module named by `name_or_id`, or `nil`.
  defp resolve_module_string(name_or_id) do
    Enum.find_value([name_or_id, "Elixir." <> name_or_id], fn cand ->
      try do
        mod = String.to_existing_atom(cand)

        cond do
          Map.has_key?(@shims, mod) -> Map.fetch!(@shims, mod)
          Code.ensure_loaded?(mod) and function_exported?(mod, :id, 0) -> mod
          true -> nil
        end
      rescue
        _ -> nil
      end
    end)
  end
end
