defmodule Photon.PrivateFileTest do
  use ExUnit.Case, async: true

  alias Photon.PrivateFile

  @moduletag :tmp_dir

  test "writes a file only its owner can read, replacing the old one whole", %{tmp_dir: dir} do
    path = Path.join([dir, "nested", "account.json"])

    assert :ok = PrivateFile.write!(path, "first")
    assert File.read!(path) == "first"
    assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600

    assert :ok = PrivateFile.write!(path, ["sec", "ond"])
    assert File.read!(path) == "second"
    assert File.ls!(Path.dirname(path)) == ["account.json"]
  end

  test "leaves the old file and no temporary one when it can't write", %{tmp_dir: dir} do
    path = Path.join(dir, "account.json")
    :ok = PrivateFile.write!(path, "kept")
    File.chmod!(dir, 0o500)
    on_exit(fn -> File.chmod!(dir, 0o700) end)

    assert_raise File.Error, fn -> PrivateFile.write!(path, "lost") end
    assert File.read!(path) == "kept"
    assert File.ls!(dir) == ["account.json"]
  end
end
