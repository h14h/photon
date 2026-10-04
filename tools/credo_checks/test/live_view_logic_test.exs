defmodule PhotonCredo.Check.LiveViewLogicTest do
  use Credo.Test.Case

  alias PhotonCredo.Check.LiveViewLogic

  @params [uses: [{"AppWeb", :live_view}, "Phoenix.LiveView"]]

  test "a LiveView that calls its context passes" do
    ~S"""
    defmodule AppWeb.CartLive do
      use AppWeb, :live_view

      def mount(_params, _session, socket) do
        if connected?(socket), do: App.Carts.subscribe()
        {:ok, assign(socket, cart: App.Carts.current())}
      end

      def handle_event("add", %{"id" => id}, socket), do: {:noreply, assign(socket, cart: App.Carts.add(id))}
    end
    """
    |> to_source_file()
    |> run_check(LiveViewLogic, @params)
    |> refute_issues()
  end

  test "persistence, I/O and PubSub in a LiveView are reported" do
    ~S"""
    defmodule AppWeb.CartLive do
      use Phoenix.LiveView
      import Ecto.Query
      alias App.Repo

      def mount(_params, _session, socket) do
        Phoenix.PubSub.subscribe(App.PubSub, "carts")
        carts = Repo.all(from c in "carts", select: c.id)
        {:ok, assign(socket, carts: carts, motd: File.read!("motd"))}
      end
    end
    """
    |> to_source_file()
    |> run_check(LiveViewLogic, @params)
    |> assert_issues(fn issues -> assert length(issues) == 4 end)
  end

  test "modules that aren't LiveViews are not checked" do
    ~S"""
    defmodule App.Carts do
      use AppWeb, :html
      def all, do: App.Repo.all("carts")
    end
    """
    |> to_source_file()
    |> run_check(LiveViewLogic, @params)
    |> refute_issues()
  end
end
