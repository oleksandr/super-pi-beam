defmodule SuperPiTest do
  use ExUnit.Case
  doctest SuperPi

  test "greets the world" do
    assert SuperPi.hello() == :world
  end
end
