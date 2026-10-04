defmodule PhotonCore.ID do
  @moduledoc """
  Identifiers that sort by creation time: 48 bits of milliseconds and 80
  random bits, in lowercase base32hex (`0-9a-v`), 26 characters. Safe as file
  names and in URLs.

  A new ID is a decision that needs the clock and randomness, so it has two
  halves: `encode/3` is pure, and `new/1` hands it the clock and `:crypto`.
  Code that has to be repeatable takes IDs (or `encode/3`'s inputs) as
  arguments instead of calling `new/1`.
  """

  @typedoc "An identifier, with its prefix if it has one."
  @type t :: String.t()

  @doc "A new identifier, optionally prefixed (`\"in_\" <> id`)."
  @spec new(String.t()) :: t()
  def new(prefix \\ "") do
    encode(prefix, System.system_time(:millisecond), :crypto.strong_rand_bytes(10))
  end

  @doc """
  The identifier for a time in milliseconds and 10 random bytes. Pure: the
  same inputs always give the same ID, and IDs from later times sort after
  IDs from earlier ones.
  """
  @spec encode(String.t(), non_neg_integer(), <<_::80>>) :: t()
  def encode(prefix, milliseconds, <<random::binary-size(10)>>) do
    prefix <>
      Base.hex_encode32(<<milliseconds::48, random::binary>>, case: :lower, padding: false)
  end

  @doc "Whether `id` is safe to use as a file name: `[0-9A-Za-z_-]`, 1 to 64 characters."
  @spec valid?(term()) :: boolean()
  def valid?(id), do: is_binary(id) and Regex.match?(~r/\A[0-9A-Za-z_-]{1,64}\z/, id)
end
