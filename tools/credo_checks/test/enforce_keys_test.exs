defmodule PhotonCredo.Check.EnforceKeysTest do
  use Credo.Test.Case

  alias PhotonCredo.Check.EnforceKeys

  test "structs with enforced keys, a struct!/2 constructor, or only defaults pass" do
    ~S"""
    defmodule App.A do
      @enforce_keys [:id]
      defstruct [:id, count: 0]
    end

    defmodule App.B do
      defstruct [:id, :name]
      def new(fields), do: struct!(__MODULE__, fields)
    end

    defmodule App.C do
      defstruct count: 0, name: nil
    end
    """
    |> to_source_file()
    |> run_check(EnforceKeys)
    |> refute_issues()
  end

  test "fields without defaults and nothing enforcing them are reported" do
    ~S"""
    defmodule App.Loose do
      defstruct [:id, :path, count: 0]
    end

    defmodule App.LooseError do
      defexception [:reason]
    end
    """
    |> to_source_file()
    |> run_check(EnforceKeys)
    |> assert_issues(fn issues ->
      assert length(issues) == 2
      assert Enum.any?(issues, &(&1.message =~ ":id, :path"))
    end)
  end
end
