defmodule Photon.Text do
  @moduledoc "Small text helpers several contexts' words share."

  # Functional core, top-level so other contexts' cores can depend on it.
  use Boundary, top_level?: true, type: :strict, deps: []

  @doc "A count with thousands separators: `123456` to `\"123,456\"`."
  @spec count(non_neg_integer()) :: String.t()
  def count(n) when is_integer(n) and n >= 0 do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  @doc """
  At most `limit` characters of `text`, ending at a word boundary when there
  is one, without trailing whitespace or `.,;:` (the caller adds any `...`).
  """
  @spec cut_at_word(String.t(), non_neg_integer()) :: String.t()
  def cut_at_word(text, limit) do
    head = String.slice(text, 0, limit + 1)

    cut =
      case Regex.run(~r/^(.*\S)\s/u, head) do
        [_, cut] -> String.slice(cut, 0, limit)
        nil -> String.slice(text, 0, limit)
      end

    String.replace(cut, ~r/[\s.,;:]+$/u, "")
  end
end
