defmodule PhotonNode.Harness.Image do
  @moduledoc """
  Recognises image formats from their first bytes and reads dimensions from
  their headers, without decoding pixels: PNG, JPEG, GIF and WebP.
  """

  # Functional core (see PhotonNode.Harness): no processes, no I/O.
  use Boundary, type: :strict, deps: []

  @typedoc "An image's format and size; width and height are nil when the header doesn't say."
  @type info :: %{
          mime: String.t(),
          width: non_neg_integer() | nil,
          height: non_neg_integer() | nil
        }

  @doc "`{:ok, %{mime, width, height}}` or `{:error, reason}`."
  @spec inspect_bytes(binary()) :: {:ok, info()} | {:error, String.t()}
  def inspect_bytes(<<0x89, "PNG\r\n", 0x1A, "\n", _::32, "IHDR", w::32, h::32, _::binary>>),
    do: {:ok, %{mime: "image/png", width: w, height: h}}

  def inspect_bytes(<<"GIF8", v, "a", w::little-16, h::little-16, _::binary>>) when v in [?7, ?9],
    do: {:ok, %{mime: "image/gif", width: w, height: h}}

  def inspect_bytes(<<"RIFF", _::32, "WEBP", rest::binary>>), do: webp(rest)

  def inspect_bytes(<<0xFF, 0xD8, rest::binary>>), do: jpeg(rest)

  def inspect_bytes(<<"BM", _::binary>>), do: {:error, ~s(unsupported image format "bmp")}
  def inspect_bytes(<<"II*", 0, _::binary>>), do: {:error, ~s(unsupported image format "tiff")}

  def inspect_bytes(<<"MM", 0, "*", _::binary>>),
    do: {:error, ~s(unsupported image format "tiff")}

  def inspect_bytes(_), do: {:error, "not a recognised image (PNG, JPEG, GIF or WebP)"}

  defp webp(<<"VP8 ", _::32, _::binary-size(6), w::little-16, h::little-16, _::binary>>),
    do:
      {:ok,
       %{mime: "image/webp", width: Bitwise.band(w, 0x3FFF), height: Bitwise.band(h, 0x3FFF)}}

  defp webp(<<"VP8L", _::32, 0x2F, b0, b1, b2, b3, _::binary>>) do
    bits = b0 + Bitwise.bsl(b1, 8) + Bitwise.bsl(b2, 16) + Bitwise.bsl(b3, 24)
    w = Bitwise.band(bits, 0x3FFF) + 1
    h = Bitwise.band(Bitwise.bsr(bits, 14), 0x3FFF) + 1
    {:ok, %{mime: "image/webp", width: w, height: h}}
  end

  defp webp(<<"VP8X", _::32, _::32, w::little-24, h::little-24, _::binary>>),
    do: {:ok, %{mime: "image/webp", width: w + 1, height: h + 1}}

  defp webp(_), do: {:ok, %{mime: "image/webp", width: nil, height: nil}}

  # Walk JPEG segments to the first start-of-frame marker.
  defp jpeg(<<0xFF, marker, _len::16, _p, h::16, w::16, _::binary>>)
       when marker in 0xC0..0xCF and marker not in [0xC4, 0xC8, 0xCC],
       do: {:ok, %{mime: "image/jpeg", width: w, height: h}}

  defp jpeg(<<0xFF, 0xFF, rest::binary>>), do: jpeg(<<0xFF, rest::binary>>)

  defp jpeg(<<0xFF, _marker, len::16, rest::binary>>)
       when len >= 2 and byte_size(rest) >= len - 2 do
    jpeg(binary_part(rest, len - 2, byte_size(rest) - (len - 2)))
  end

  defp jpeg(_), do: {:ok, %{mime: "image/jpeg", width: nil, height: nil}}
end
