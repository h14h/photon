defmodule Photon.NodeDistTest do
  use ExUnit.Case, async: true

  alias Photon.NodeDist

  @latest "0.1.0+20260923060000"
  @caps ["attachments"]

  test "a node is out of date when its build is older than the hub's" do
    assert NodeDist.outdated?(
             %{"version" => "0.1.0+20260922000000", "capabilities" => @caps},
             @latest
           )

    refute NodeDist.outdated?(%{"version" => @latest, "capabilities" => @caps}, @latest)

    refute NodeDist.outdated?(
             %{"version" => "0.1.0+20260924000000", "capabilities" => @caps},
             @latest
           )
  end

  test "nodes from before capabilities are always out of date" do
    assert NodeDist.outdated?(%{"version" => "0.1.0+20260923060000"}, @latest)
    assert NodeDist.outdated?(%{"version" => "0.1.0"}, @latest)
  end

  test "current nodes without a build stamp are not compared by build" do
    refute NodeDist.outdated?(%{"version" => "0.1.0", "capabilities" => @caps}, @latest)

    refute NodeDist.outdated?(
             %{"version" => "0.1.0+20260922000000", "capabilities" => @caps},
             nil
           )
  end
end
