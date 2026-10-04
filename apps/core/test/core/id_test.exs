defmodule PhotonCore.IDTest do
  use PhotonCore.Case, async: true

  @random <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10>>

  describe "encode/3" do
    test "is 26 lowercase base32hex characters after the prefix" do
      id = ID.encode("in_", 1_700_000_000_000, @random)
      assert "in_" <> rest = id
      assert rest =~ ~r/\A[0-9a-v]{26}\z/
      assert ID.valid?(id)
    end

    test "gives the same ID for the same inputs" do
      assert ID.encode("", 5, @random) == ID.encode("", 5, @random)
    end

    test "sorts by time, whatever the random bytes" do
      earlier = ID.encode("", 1_000, :binary.copy(<<255>>, 10))
      later = ID.encode("", 1_001, :binary.copy(<<0>>, 10))
      assert earlier < later
    end
  end

  describe "new/1" do
    # The clock and RNG make each ID different, so only its shape is checked.
    test "makes distinct, valid IDs with the prefix" do
      ids = for _ <- 1..20, do: ID.new("op_")
      assert Enum.uniq(ids) == ids
      assert Enum.all?(ids, &(String.starts_with?(&1, "op_") and ID.valid?(&1)))
    end
  end

  describe "valid?/1" do
    test "accepts file-name-safe text of 1 to 64 characters" do
      assert ID.valid?("abc_DEF-123")
      refute ID.valid?("")
      refute ID.valid?("../etc")
      refute ID.valid?(String.duplicate("a", 65))
      refute ID.valid?(nil)
    end
  end
end
