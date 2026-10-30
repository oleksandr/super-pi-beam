defmodule SuperPi.Harness.DSL do
  @moduledoc """
  The `use SuperPi.Harness` macro, kept in a module with no runtime dependencies.

  `use` makes a compile-time dependency on the used module. `SuperPi.Harness` reaches the
  built-in harnesses and plugins at runtime, so the built-in harnesses `use` this module
  directly to stay out of a compile-time cycle. `use SuperPi.Harness` forwards here.
  """

  @doc false
  defmacro __using__(opts) do
    quote do
      @behaviour SuperPi.Harness

      # The declaration is evaluated on each call, so plugin options may read application config.
      @doc false
      def __harness__, do: unquote(opts)

      @impl SuperPi.Harness
      def id, do: Keyword.fetch!(__harness__(), :id)

      @impl SuperPi.Harness
      def name, do: Keyword.fetch!(__harness__(), :name)

      @impl SuperPi.Harness
      def description, do: Keyword.fetch!(__harness__(), :description)

      @impl SuperPi.Harness
      def extensions(opts \\ []) do
        extra = Keyword.get(opts, :extra_plugins, [])
        SuperPi.Plugins.resolve_all(Keyword.get(__harness__(), :plugins, []) ++ extra)
      end

      @impl SuperPi.Harness
      def agent_defaults(opts \\ []), do: SuperPi.Harness.Defaults.build(__MODULE__, opts)

      @impl SuperPi.Harness
      def capabilities, do: SuperPi.Harness.Defaults.capabilities(__MODULE__)

      defoverridable id: 0,
                     name: 0,
                     description: 0,
                     extensions: 1,
                     agent_defaults: 1,
                     capabilities: 0
    end
  end
end
