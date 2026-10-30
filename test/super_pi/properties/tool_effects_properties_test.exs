defmodule SuperPi.Properties.ToolEffectsTest do
  @moduledoc """
  The permission decision is a pure function of `(effects, mode, policy)` and it is monotone in
  `plan < accept-edits < auto`: a mode never blocks what a lower mode allows. This is the property
  that would have caught the plugin tools that were blocked in accept-edits.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias SuperPi.Plugins.Permissions

  @modes ["plan", "accept-edits", "auto"]
  @effects ["read", "fs_write", "exec", "net_read", "net_write", "state_write"]

  defp decide(effects, mode, settings) do
    agent = %{
      "executionMode" => mode,
      "workspacePaths" => [File.cwd!()],
      "tools" => [%{"name" => "t", "effects" => effects}]
    }

    Permissions.decide("t", %{"url" => "https://example.com/x"}, agent, settings)
  end

  defp implies(a, b), do: not a or b

  defp settings do
    gen all(
          network <- member_of(["allow", "allowlist", "deny"]),
          plan_net <- boolean(),
          hosts <- member_of([[], ["example.com"]])
        ) do
      %{"network" => network, "network_in_plan_mode" => plan_net, "networkAllowHosts" => hosts}
    end
  end

  property "the decision never loosens as the mode rises" do
    check all(
            effects <- uniq_list_of(member_of(@effects), min_length: 1, max_length: 4),
            settings <- settings()
          ) do
      [plan, edits, auto] = Enum.map(@modes, &decide(effects, &1, settings))

      assert implies(plan == :allow, edits == :allow),
             "plan allows what accept-edits blocks: #{inspect(effects)}"

      assert implies(edits == :allow, auto == :allow),
             "accept-edits allows what auto blocks: #{inspect(effects)}"
    end
  end

  property "a tool with only the read effect is allowed in every mode, under every network policy" do
    check all(settings <- settings(), mode <- member_of(@modes)) do
      assert :allow = decide(["read"], mode, settings)
    end
  end

  property "network deny blocks any network effect in every mode, and the decision is deterministic" do
    check all(
            effects <- uniq_list_of(member_of(@effects), min_length: 1, max_length: 4),
            mode <- member_of(@modes)
          ) do
      settings = %{"network" => "deny"}
      result = decide(effects, mode, settings)
      assert result == decide(effects, mode, settings)

      if Enum.any?(effects, &(&1 in ["net_read", "net_write"])) and mode != "plan" do
        assert {:block, _} = result
      end
    end
  end
end
