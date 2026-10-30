defmodule SuperPi.Harness.Legacy do
  @moduledoc """
  Delegating shims for the harness modules of earlier releases.

  `SuperPi.Harness.resolve/1` accepts a module name, so a client may pin one. The shims keep those
  names working for one release. Each delegates to its successor, so `id/0` returns the successor's
  id, not the old one. `SuperPi.Harness.resolve/1` maps a shim to its successor directly.

  | Shim | Successor |
  |---|---|
  | `SuperPi.Harness.Workspace`, `SuperPi.Harness.Autonomous` | `SuperPi.Harness.Code` |
  | `SuperPi.Harness.Default`, `SuperPi.Harness.Fast`, `SuperPi.Harness.Interactive` | `SuperPi.Harness.Assistant` |

  `SuperPi.Harness.Fast` no longer sets `effort: "low"`. Pass `--effort low` or `effort: "low"`.
  """

  @doc false
  defmacro __using__(opts) do
    target = Keyword.fetch!(opts, :to)

    quote do
      @behaviour SuperPi.Harness
      @target unquote(target)

      @impl true
      defdelegate id, to: @target
      @impl true
      defdelegate name, to: @target
      @impl true
      defdelegate description, to: @target
      @impl true
      defdelegate extensions(opts \\ []), to: @target
      @impl true
      defdelegate agent_defaults(opts \\ []), to: @target
      @impl true
      defdelegate capabilities, to: @target
    end
  end
end

defmodule SuperPi.Harness.Workspace do
  @moduledoc "Deprecated. Delegates to `SuperPi.Harness.Code`. See `SuperPi.Harness.Legacy`."
  use SuperPi.Harness.Legacy, to: SuperPi.Harness.Code
end

defmodule SuperPi.Harness.Autonomous do
  @moduledoc "Deprecated. Delegates to `SuperPi.Harness.Code`. See `SuperPi.Harness.Legacy`."
  use SuperPi.Harness.Legacy, to: SuperPi.Harness.Code
end

defmodule SuperPi.Harness.Default do
  @moduledoc "Deprecated. Delegates to `SuperPi.Harness.Assistant`. See `SuperPi.Harness.Legacy`."
  use SuperPi.Harness.Legacy, to: SuperPi.Harness.Assistant
end

defmodule SuperPi.Harness.Fast do
  @moduledoc "Deprecated. Delegates to `SuperPi.Harness.Assistant`. See `SuperPi.Harness.Legacy`."
  use SuperPi.Harness.Legacy, to: SuperPi.Harness.Assistant
end

defmodule SuperPi.Harness.Interactive do
  @moduledoc "Deprecated. Delegates to `SuperPi.Harness.Assistant`. See `SuperPi.Harness.Legacy`."
  use SuperPi.Harness.Legacy, to: SuperPi.Harness.Assistant
end
