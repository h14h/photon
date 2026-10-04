defmodule PhotonNode.Property.OutputTest do
  @moduledoc """
  `Output.bound/3` caps what a tool result shows the model: at most `limit`
  code points unless it says it truncated, keeping the head and tail, and
  always valid UTF-8.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias PhotonNode.Harness.Output

  defp text do
    one_of([
      binary(max_length: 60),
      string(:utf8, max_length: 60),
      string(:printable, max_length: 60),
      # Valid text with invalid bytes spliced in.
      map(
        {string(:utf8, max_length: 20), binary(max_length: 3), string(:utf8, max_length: 20)},
        fn {a, b, c} ->
          a <> b <> c
        end
      )
    ])
  end

  property "bounded output is valid UTF-8, within the limit or marked, with head and tail kept" do
    check all(
            text <- text(),
            limit <- integer(0..70),
            path <- one_of([constant(nil), constant("/tmp/out")]),
            max_runs: 500
          ) do
      {out, truncated?} = Output.bound(text, limit, path)
      clean = Output.sanitize(text)
      chars = String.to_charlist(clean)

      assert String.valid?(out)
      assert String.valid?(clean)

      if truncated? do
        assert length(chars) > limit
        head = chars |> Enum.take(div(limit, 2)) |> List.to_string()
        tail = chars |> Enum.drop(length(chars) - (limit - div(limit, 2))) |> List.to_string()
        assert String.starts_with?(out, head)
        assert String.ends_with?(out, tail)

        middle =
          binary_part(out, byte_size(head), byte_size(out) - byte_size(head) - byte_size(tail))

        assert [_, skipped | rest] =
                 Regex.run(
                   ~r/\A\.\.\.(\d+) bytes truncated(; complete output in (.*))?\.\.\.\z/s,
                   middle
                 )

        assert String.to_integer(skipped) == byte_size(clean) - byte_size(head) - byte_size(tail)
        if path, do: assert(List.last(rest) == path), else: assert(rest == [])
      else
        assert out == clean
        assert length(chars) <= limit
      end
    end
  end

  property "sanitize keeps valid text and only replaces invalid bytes" do
    check all(text <- text(), max_runs: 300) do
      clean = Output.sanitize(text)
      assert String.valid?(clean)
      if String.valid?(text), do: assert(clean == text)
    end
  end

  property "bound! agrees with bound" do
    check all(text <- text(), limit <- integer(0..30), max_runs: 100) do
      assert Output.bound!(text, limit) == elem(Output.bound(text, limit), 0)
    end
  end
end
