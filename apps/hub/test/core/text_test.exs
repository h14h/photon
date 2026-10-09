defmodule Photon.TextTest do
  use Photon.Case, async: true

  alias Photon.Text

  test "count/1 groups thousands" do
    assert Text.count(0) == "0"
    assert Text.count(999) == "999"
    assert Text.count(1_000) == "1,000"
    assert Text.count(123_456_789) == "123,456,789"
  end

  describe "cut_at_word/2" do
    test "leaves short text alone and cuts long text at a word" do
      assert Text.cut_at_word("short", 10) == "short"
      assert Text.cut_at_word("check the pump in the garden", 14) == "check the pump"
    end

    test "drops trailing punctuation and whitespace, and cuts one long word where it must" do
      assert Text.cut_at_word("done, then more", 6) == "done"
      assert Text.cut_at_word("supercalifragilistic", 5) == "super"
    end
  end
end
