defmodule SuperPi.ExtensionContractTest do
  use ExUnit.Case, async: true
  alias SuperPi.Extension

  defmodule Undeclared do
    use SuperPi.Extension
    def after_run(_, ctx), do: send(ctx.owner, :unsafe_hook)
  end

  defmodule Bare do
    def before_agent_start(agent, _), do: {:ok, Map.put(agent, "bare", true)}
    def after_run(_, ctx), do: send(ctx.owner, :unsafe_hook)
  end

  defmodule Durable do
    use SuperPi.Extension
    def lifecycle_effects, do: []
    def before_agent_start(agent, _), do: {:ok, Map.put(agent, "durable", true)}
  end

  defmodule Request do
    use SuperPi.Extension
    def lifecycle_effects, do: []
    def prepare_request(agent, _), do: {:ok, Map.put(agent, "request", agent["durable"])}
  end

  defmodule LaterRequest do
    use SuperPi.Extension
    def prepare_request(agent, _), do: {:ok, Map.put(agent, "later", agent["request"])}
  end

  defmodule OldRequest do
    def before_agent_start(agent, _), do: {:request, agent}
  end

  test "undeclared lifecycle hooks are disabled in plan, including modules without the callback" do
    extensions = [Undeclared, Bare, Durable, Request]
    assert Extension.active(extensions, %{"executionMode" => "plan"}) == [Durable, Request]

    Extension.run_after_run(Extension.active(extensions, %{"executionMode" => "plan"}), %{}, %{
      owner: self()
    })

    refute_received :unsafe_hook
    assert Extension.active(extensions, %{"executionMode" => "accept-edits"}) == extensions
  end

  test "durable hooks all finish before request hooks, independently of interleaving" do
    for extensions <- [[Request, Durable], [Durable, Request]] do
      {stored, request} = Extension.run_agent_start(extensions, %{}, %{})
      assert stored["durable"] == true
      refute Map.has_key?(stored, "request")
      assert request["request"] == true
    end
  end

  test "request hooks keep their declared composition order" do
    {stored, request} = Extension.run_agent_start([Request, Durable, LaterRequest], %{}, %{})
    assert request["later"] == true
    refute Map.has_key?(stored, "later")
  end

  test "a legacy plugin without phase callbacks still has durable semantics" do
    {stored, request} = Extension.run_agent_start([Request, Bare, Durable], %{}, %{})
    assert stored["bare"] == true
    assert request["bare"] == true
  end

  test "ambiguous legacy request results fail with migration guidance" do
    assert_raise ArgumentError, ~r/use prepare_request/, fn ->
      Extension.run_agent_start([OldRequest, Durable], %{}, %{})
    end
  end
end
