defmodule PhotonNode.Harness.ImageTest do
  use PhotonNode.Case, async: true

  alias PhotonNode.Harness.Image

  describe "inspect_bytes/1" do
    test "reads the size from PNG, GIF and JPEG headers" do
      png = <<0x89, "PNG\r\n", 0x1A, "\n", 13::32, "IHDR", 2::32, 3::32, 0>>
      assert {:ok, %{mime: "image/png", width: 2, height: 3}} = Image.inspect_bytes(png)

      gif = <<"GIF89a", 5::little-16, 7::little-16, 0>>
      assert {:ok, %{mime: "image/gif", width: 5, height: 7}} = Image.inspect_bytes(gif)

      # An APP0 segment to skip, then the start-of-frame marker.
      jpeg = <<0xFF, 0xD8, 0xFF, 0xE0, 4::16, 0, 0, 0xFF, 0xC0, 17::16, 8, 9::16, 10::16, 0>>
      assert {:ok, %{mime: "image/jpeg", width: 10, height: 9}} = Image.inspect_bytes(jpeg)
    end

    test "reads the size from each kind of WebP" do
      vp8x = <<"RIFF", 0::32, "WEBP", "VP8X", 0::32, 0::32, 99::little-24, 49::little-24>>
      assert {:ok, %{mime: "image/webp", width: 100, height: 50}} = Image.inspect_bytes(vp8x)

      bits = 99 + Bitwise.bsl(49, 14)
      vp8l = <<"RIFF", 0::32, "WEBP", "VP8L", 0::32, 0x2F, bits::little-32>>
      assert {:ok, %{width: 100, height: 50}} = Image.inspect_bytes(vp8l)

      vp8 = <<"RIFF", 0::32, "WEBP", "VP8 ", 0::32, 0::48, 100::little-16, 50::little-16>>
      assert {:ok, %{width: 100, height: 50}} = Image.inspect_bytes(vp8)

      other = <<"RIFF", 0::32, "WEBP", "ALPH">>
      assert {:ok, %{mime: "image/webp", width: nil, height: nil}} = Image.inspect_bytes(other)
    end

    test "names formats it doesn't take, and refuses what isn't an image" do
      assert {:error, ~s(unsupported image format "bmp")} = Image.inspect_bytes("BM....")
      assert {:error, ~s(unsupported image format "tiff")} = Image.inspect_bytes(<<"II*", 0>>)
      assert {:error, ~s(unsupported image format "tiff")} = Image.inspect_bytes(<<"MM", 0, "*">>)
      assert {:error, "not a recognised image" <> _} = Image.inspect_bytes("hello")
    end
  end
end
