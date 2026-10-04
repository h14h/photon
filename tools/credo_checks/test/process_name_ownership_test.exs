defmodule PhotonCredo.Check.ProcessNameOwnershipTest do
  use Credo.Test.Case

  alias PhotonCredo.Check.ProcessNameOwnership

  @params [
    names: [{"App.NodeRegistry", ["App.Nodes", "App.Application"]}],
    api_modules: ["App.Nodes"]
  ]

  test "the owner names its process and its API returns data" do
    ~S"""
    defmodule App.Nodes do
      @spec start_link(keyword()) :: GenServer.on_start()
      def start_link(opts), do: Registry.start_link(keys: :unique, name: App.NodeRegistry)

      @spec list() :: [map()]
      def list, do: Registry.select(App.NodeRegistry, [])

      @spec register(String.t()) :: :ok
      def register(id) do
        {:ok, _} = Registry.register(App.NodeRegistry, id, %{})
        :ok
      end
    end
    """
    |> to_source_file()
    |> run_check(ProcessNameOwnership, @params)
    |> refute_issues()
  end

  test "another module naming the process is reported" do
    ~S"""
    defmodule App.Web.NodeChannel do
      alias App.NodeRegistry
      def join(id), do: Registry.register(NodeRegistry, id, %{})
    end
    """
    |> to_source_file()
    |> run_check(ProcessNameOwnership, @params)
    |> assert_issues(fn issues ->
      assert Enum.all?(issues, &(&1.message =~ "App.NodeRegistry"))
    end)
  end

  test "an API that hands out processes is reported" do
    ~S"""
    defmodule App.Nodes do
      @spec channel(String.t()) :: pid() | nil
      def channel(id), do: lookup(id)

      @spec server() :: GenServer.server()
      def server, do: App.NodeServer

      def via(id), do: {:via, Registry, {App.NodeRegistry, id}}

      def name_for(id) do
        id = String.trim(id)
        {:via, Registry, {App.NodeRegistry, id}}
      end

      defp lookup(_id), do: nil
    end
    """
    |> to_source_file()
    |> run_check(ProcessNameOwnership, @params)
    |> assert_issues(fn issues ->
      assert issues |> Enum.map(& &1.trigger) |> Enum.sort() == ~w(channel name_for server via)
    end)
  end
end
