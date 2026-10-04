defmodule PhotonCredo.Check.PreferCallTest do
  use Credo.Test.Case

  alias PhotonCredo.Check.PreferCall

  test "calls and sends to self pass" do
    ~S"""
    defmodule App.Server do
      def add(item), do: GenServer.call(__MODULE__, {:add, item})

      def init(state) do
        send(self(), :boot)
        Process.send_after(self(), :tick, 1_000)
        {:ok, state}
      end
    end
    """
    |> to_source_file()
    |> run_check(PreferCall)
    |> refute_issues()
  end

  test "casts, handle_cast and sends to other processes are reported" do
    ~S"""
    defmodule App.Server do
      def add(item), do: GenServer.cast(__MODULE__, {:add, item})
      def handle_cast({:add, item}, state), do: {:noreply, [item | state]}
      def poke(pid), do: send(pid, :poke)
      def later(pid), do: Process.send_after(pid, :poke, 10)
    end
    """
    |> to_source_file()
    |> run_check(PreferCall)
    |> assert_issues(fn issues -> assert length(issues) == 4 end)
  end

  test "an allow-listed module needs a reason" do
    code = ~S"""
    defmodule App.Notifier do
      def notify(pid), do: send(pid, :changed)
    end
    """

    code
    |> to_source_file()
    |> run_check(PreferCall, allowed: [{"App.Notifier", "lost notifications are recovered"}])
    |> refute_issues()

    code
    |> to_source_file()
    |> run_check(PreferCall, allowed: [{"App.Notifier", ""}])
    |> assert_issue()
  end

  test "a module's own send/2 is not Kernel.send" do
    ~S"""
    defmodule App.Mailer do
      import Kernel, except: [send: 2]
      def send(to, text), do: {to, text}
      def welcome(to), do: send(to, "hi")
    end
    """
    |> to_source_file()
    |> run_check(PreferCall)
    |> refute_issues()
  end
end
