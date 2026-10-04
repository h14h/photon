defmodule Photon.NodeDistTest do
  @moduledoc "Which build a machine needs, and whether a node is out of date."

  use Photon.Case, async: true

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

  test "maps uname output to a build target" do
    assert NodeDist.target("Linux", "x86_64") == {:ok, "linux-x86_64"}
    assert NodeDist.target("Darwin", "arm64") == {:ok, "macos-aarch64"}
    assert NodeDist.target("Linux", "amd64") == {:ok, "linux-x86_64"}
    assert NodeDist.target("Windows", "x86_64") == :error
    assert NodeDist.package_target("linux-x86_64") == "linux_x86_64"
  end
end
