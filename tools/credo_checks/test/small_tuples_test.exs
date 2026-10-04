defmodule PhotonCredo.Check.SmallTuplesTest do
  use Credo.Test.Case

  alias PhotonCredo.Check.SmallTuples

  test "small and tagged tuples, OTP messages and typespecs pass" do
    ~S"""
    defmodule App.Events do
      @type event :: {:retry, pos_integer(), non_neg_integer(), term(), term()}

      def point(x, y, z), do: {x, y, z}
      def retry(attempt, delay, error), do: {:retry, attempt, delay, error}
      def handle_info({:DOWN, _ref, :process, _pid, reason}, state), do: {:noreply, {state, reason}}
      def second(tuple), do: elem(tuple, 1)
      def loopback?({127, _, _, _}), do: true
      def loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
      def loopback?({_, _, _, _}), do: false
    end
    """
    |> to_source_file()
    |> run_check(SmallTuples)
    |> refute_issues()
  end

  test "large tuples and deep elem/2 reads are reported" do
    ~S"""
    defmodule App.Events do
      def item(a, b, c, d), do: {a, b, c, d}
      def result(id, name, parts, done), do: {:result, id, name, parts, done}
      def third(tuple), do: elem(tuple, 2)
      def piped(tuple), do: tuple |> elem(3)
    end
    """
    |> to_source_file()
    |> run_check(SmallTuples)
    |> assert_issues(fn issues -> assert length(issues) == 4 end)
  end
end
