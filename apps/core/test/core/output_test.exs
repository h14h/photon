defmodule PhotonCore.OutputTest do
  use PhotonCore.Case, async: true

  test "keeps head and tail around a byte count and path" do
    assert {"h...2 bytes truncated; complete output in /x/out...lo", true} =
             Output.bound("hello", 3, "/x/out")

    assert {"hello", false} = Output.bound("hello", 5)
  end

  test "counts code points, not bytes" do
    assert {"héllo", false} = Output.bound("héllo", 5)
  end

  describe "truncated/5" do
    test "joins the head of one text and the tail of another around the bytes left out" do
      # A 1000-byte file read as its first and last bytes, bounded to 6 code points.
      assert Output.truncated("abcdef", "uvwxyz", 1000, 6, "/x/out") ==
               "abc...994 bytes truncated; complete output in /x/out...xyz"
    end

    test "is what bound/3 gives for the whole text" do
      text = String.duplicate("héllo ", 20)
      {bounded, true} = Output.bound(text, 11, "/x/out")
      assert Output.truncated(text, text, byte_size(text), 11, "/x/out") == bounded
    end

    test "replaces invalid bytes in the ends it keeps" do
      assert Output.truncated(<<"ab", 255>>, <<255, "yz">>, 20, 6, nil) ==
               "ab\uFFFD...10 bytes truncated...\uFFFDyz"
    end
  end
end
