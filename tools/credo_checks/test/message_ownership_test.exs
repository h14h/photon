defmodule PhotonCredo.Check.MessageOwnershipTest do
  use Credo.Test.Case

  alias PhotonCredo.Check.MessageOwnership

  test "a client function in the server's own module passes" do
    ~S"""
    defmodule App.Counter do
      use GenServer
      def increment(name), do: GenServer.call(name, {:increment, 1})
      def reset(name), do: GenServer.call(name, :reset)
      def forward(name, message), do: GenServer.call(name, message)

      def handle_call({:increment, n}, _from, count), do: {:reply, :ok, count + n}
      def handle_call(:reset, _from, _count), do: {:reply, :ok, 0}
    end
    """
    |> to_source_file()
    |> run_check(MessageOwnership)
    |> refute_issues()
  end

  test "a literal message sent from another module is reported" do
    ~S"""
    defmodule App.Caller do
      def bump(name) do
        GenServer.call(name, {:increment, 1})
        GenServer.cast(name, :reset)
      end
    end
    """
    |> to_source_file()
    |> run_check(MessageOwnership)
    |> assert_issues(fn issues -> assert length(issues) == 2 end)
  end

  test "a message the module doesn't handle is reported; a catch-all handles everything" do
    ~S"""
    defmodule App.Counter do
      def stop(name), do: GenServer.call(name, :stop)
      def handle_call(:reset, _from, _count), do: {:reply, :ok, 0}
    end
    """
    |> to_source_file()
    |> run_check(MessageOwnership)
    |> assert_issue(fn issue -> assert issue.message =~ ":stop" end)

    ~S"""
    defmodule App.Proxy do
      def stop(name), do: GenServer.call(name, {:stop, :now})
      def handle_call(message, _from, state), do: {:reply, message, state}
    end
    """
    |> to_source_file()
    |> run_check(MessageOwnership)
    |> refute_issues()
  end
end
