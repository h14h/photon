defmodule PhotonCredo.Check.AccumulatorConcatTest do
  use Credo.Test.Case

  alias PhotonCredo.Check.AccumulatorConcat

  test "iodata and map_join pass" do
    ~S"""
    defmodule App.Render do
      def lines(items), do: Enum.map_join(items, "\n", & &1.name)

      def iodata(items) do
        items
        |> Enum.reduce([], fn item, acc -> [acc, item.name, "\n"] end)
        |> IO.iodata_to_binary()
      end

      def label(item), do: Enum.reduce(item.tags, 0, fn tag, count -> count + byte_size("#" <> tag) end)
    end
    """
    |> to_source_file()
    |> run_check(AccumulatorConcat)
    |> refute_issues()
  end

  test "concatenating onto the accumulator is reported" do
    ~S"""
    defmodule App.Render do
      def lines(items), do: Enum.reduce(items, "", fn item, acc -> acc <> item.name <> "\n" end)
      def folded(items), do: List.foldl(items, "", fn item, out -> item <> out end)

      def comprehended(items) do
        for item <- items, reduce: "" do
          text -> text <> item
        end
      end
    end
    """
    |> to_source_file()
    |> run_check(AccumulatorConcat)
    |> assert_issues(fn issues -> assert length(issues) == 3 end)
  end
end
