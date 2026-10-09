defmodule PhotonCredo.Check.FunctionalCoreTest do
  use Credo.Test.Case

  alias PhotonCredo.Check.FunctionalCore

  @params [core_modules: ["App.Core.*"]]

  test "a pure core module passes" do
    ~S"""
    defmodule App.Core.Cart do
      @prompt File.read!("prompt.md")

      def total(items), do: items |> Enum.map(& &1.price) |> Enum.sum()
      def label(cart), do: "#{@prompt}: #{total(cart.items)}"
    end
    """
    |> to_source_file()
    |> run_check(FunctionalCore, @params)
    |> refute_issues()
  end

  test "process and I/O primitives in core modules are reported" do
    ~S"""
    defmodule App.Core.Cart do
      alias App.Repo

      def save(cart) do
        Repo.insert!(cart)
        File.write!("cart", "x")
        GenServer.call(App.Server, :ping)
        send(App.Server, :saved)
        Phoenix.PubSub.broadcast(App.PubSub, "carts", :saved)
        System.cmd("ls", [])
        :ets.insert(:carts, {1, cart})
      end
    end
    """
    |> to_source_file()
    |> run_check(FunctionalCore, @params)
    |> assert_issues(fn issues -> assert length(issues) == 7 end)
  end

  test "modules outside the core are not checked" do
    ~S"""
    defmodule App.Boundary.Server do
      def save(cart), do: File.write!("cart", cart)
    end
    """
    |> to_source_file()
    |> run_check(FunctionalCore, @params)
    |> refute_issues()
  end

  test "nondeterministic calls are reported unless allowed for the module" do
    code = ~S"""
    defmodule App.Core.Ids do
      def new, do: {App.ID.new(), DateTime.utc_now(), :rand.uniform(6)}
    end
    """

    code
    |> to_source_file()
    |> run_check(FunctionalCore, @params ++ [nondeterministic_extra: ["App.ID.new"]])
    |> assert_issues(fn issues -> assert length(issues) == 3 end)

    code
    |> to_source_file()
    |> run_check(
      FunctionalCore,
      @params ++
        [
          nondeterministic_extra: ["App.ID.new"],
          allowed: [{"App.Core.Ids", ["App.ID.new", "DateTime.utc_now", ":rand"]}]
        ]
    )
    |> refute_issues()
  end

  test "receive and spawn are reported, a module's own send/2 is not Kernel.send" do
    ~S"""
    defmodule App.Core.Loop do
      def wait do
        spawn(fn -> :ok end)
        receive do
          msg -> msg
        end
      end
    end
    """
    |> to_source_file()
    |> run_check(FunctionalCore, @params)
    |> assert_issues(fn issues -> assert length(issues) == 2 end)

    ~S"""
    defmodule App.Core.Mail do
      import Kernel, except: [send: 2]
      def send(to, text), do: %{to: to, text: text}
      def reply(to), do: send(to, "ok")
    end
    """
    |> to_source_file()
    |> run_check(FunctionalCore, @params)
    |> refute_issues()
  end

  test "the namespace pattern and exact names both work" do
    code = ~S"""
    defmodule App.Core do
      def now, do: Logger.info("x")
    end
    """

    code |> to_source_file() |> run_check(FunctionalCore, @params) |> assert_issue()

    code
    |> to_source_file()
    |> run_check(FunctionalCore, core_modules: ["App.Core.Cart"])
    |> refute_issues()
  end

  test "calls into the app's own boundary modules are reported, calls to core modules aren't" do
    ~S"""
    defmodule App.Core.Cart do
      alias App.Core.Price
      alias App.Orders

      def total(cart), do: Enum.sum(Enum.map(cart.items, &Price.of/1))
      def place(cart), do: Orders.place(cart)
      def owner(cart), do: App.Accounts.get(cart.owner_id)
      def text(cart), do: Jason.encode!(cart)
    end
    """
    |> to_source_file()
    |> run_check(FunctionalCore, core_modules: ["App.Core.*"], namespaces: ["App"])
    |> assert_issues(fn issues ->
      assert issues |> Enum.map(& &1.trigger) |> Enum.sort() == ["get", "place"]
      assert Enum.all?(issues, &(&1.message =~ "a boundary module"))
    end)
  end

  test "an allowed call into a boundary module passes" do
    ~S"""
    defmodule App.Core.Turn do
      def spec(tool), do: App.Tool.spec(tool)
    end
    """
    |> to_source_file()
    |> run_check(FunctionalCore,
      core_modules: ["App.Core.*"],
      namespaces: ["App"],
      allowed: [{"App.Core.Turn", ["App.Tool.spec"]}]
    )
    |> refute_issues()
  end
end
