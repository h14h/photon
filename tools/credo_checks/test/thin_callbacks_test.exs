defmodule PhotonCredo.Check.ThinCallbacksTest do
  use Credo.Test.Case

  alias PhotonCredo.Check.ThinCallbacks

  test "short callbacks pass" do
    ~S"""
    defmodule App.Server do
      use GenServer

      def handle_call({:add, item}, _from, state) do
        state = App.Cart.add(state, item)
        {:reply, :ok, state}
      end

      def handle_info(:tick, state), do: {:noreply, App.Cart.tick(state)}
    end
    """
    |> to_source_file()
    |> run_check(ThinCallbacks, max_lines: 3)
    |> refute_issues()
  end

  test "a long callback clause is reported" do
    ~S"""
    defmodule App.Server do
      use GenServer

      def handle_info(:tick, state) do
        a = 1
        b = 2
        c = a + b
        {:noreply, Map.put(state, :c, c)}
      end
    end
    """
    |> to_source_file()
    |> run_check(ThinCallbacks, max_lines: 3)
    |> assert_issue(fn issue -> assert issue.message =~ "4-line clause" end)
  end

  test "only the configured callbacks count, and excluded modules are skipped" do
    code = ~S"""
    defmodule App.Live do
      def handle_event("save", params, socket) do
        a = params
        b = a
        c = b
        {:noreply, assign(socket, c: c)}
      end
    end
    """

    code |> to_source_file() |> run_check(ThinCallbacks, max_lines: 3) |> refute_issues()

    code
    |> to_source_file()
    |> run_check(ThinCallbacks, max_lines: 3, callbacks: [:handle_event])
    |> assert_issue()

    code
    |> to_source_file()
    |> run_check(ThinCallbacks,
      max_lines: 3,
      callbacks: [:handle_event],
      excluded_modules: ["App.Live"]
    )
    |> refute_issues()
  end
end
