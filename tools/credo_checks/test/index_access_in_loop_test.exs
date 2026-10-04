defmodule PhotonCredo.Check.IndexAccessInLoopTest do
  use Credo.Test.Case

  alias PhotonCredo.Check.IndexAccessInLoop

  test "a single index read and zipped walks pass" do
    ~S"""
    defmodule App.Grid do
      def first(rows), do: Enum.at(rows, 0)
      def pairs(xs, ys), do: Enum.zip_with(xs, ys, &{&1, &2})
    end
    """
    |> to_source_file()
    |> run_check(IndexAccessInLoop)
    |> refute_issues()
  end

  test "index reads inside loops are reported" do
    ~S"""
    defmodule App.Grid do
      def pairs(xs, ys), do: Enum.map(Enum.with_index(xs), fn {x, i} -> {x, Enum.at(ys, i)} end)
      def column(rows, i), do: for(row <- rows, do: Enum.fetch!(row, i))
      def captured(rows), do: Enum.map(0..2, &Enum.at(rows, &1))
    end
    """
    |> to_source_file()
    |> run_check(IndexAccessInLoop)
    |> assert_issues(fn issues -> assert length(issues) == 3 end)
  end
end
