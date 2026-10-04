defmodule PhotonCredo.Check.DeepAccessPathTest do
  use Credo.Test.Case

  alias PhotonCredo.Check.DeepAccessPath

  test "shallow paths pass" do
    ~S"""
    defmodule App.Board do
      def get(board, row), do: get_in(board, [:rows, row])
      def set(state, key, value), do: put_in(state.cells[key], value)
      def put(state, value), do: put_in(state, [:a, :b], [1, 2, 3])
      def bump(state), do: update_in(state.count, &(&1 + 1))
    end
    """
    |> to_source_file()
    |> run_check(DeepAccessPath)
    |> refute_issues()
  end

  test "deep paths are reported" do
    ~S"""
    defmodule App.Board do
      def get(board), do: get_in(board, ["state", "result", "error"])
      def set(state, value), do: put_in(state.board.rows[:a], value)
      def piped(board), do: board |> get_in([:a, :b, :c, :d])
    end
    """
    |> to_source_file()
    |> run_check(DeepAccessPath)
    |> assert_issues(fn issues -> assert length(issues) == 3 end)
  end

  test "the depth is a parameter" do
    ~S"""
    defmodule App.Board do
      def get(board), do: get_in(board, [:a, :b, :c])
    end
    """
    |> to_source_file()
    |> run_check(DeepAccessPath, max_depth: 3)
    |> refute_issues()
  end
end
