defmodule PhotonCredo.Check.EnforceKeysTest do
  use Credo.Test.Case

  alias PhotonCredo.Check.EnforceKeys

  test "structs whose fields are enforced or have defaults pass" do
    ~S"""
    defmodule App.A do
      @enforce_keys [:id]
      defstruct [:id, count: 0]
    end

    defmodule App.B do
      @enforce_keys [:id, :name]
      defstruct [:id, :name, note: nil]
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

  test "a field @enforce_keys leaves out is reported, even with a struct!/2 constructor" do
    ~S"""
    defmodule App.Partial do
      @enforce_keys [:id]
      defstruct [:id, :name]
    end

    defmodule App.Empty do
      @enforce_keys []
      defstruct [:id]
    end

    defmodule App.Constructed do
      defstruct [:id, :name]
      def new(fields), do: struct!(__MODULE__, fields)
    end

    defmodule App.Other do
      defstruct [:id]
      def new(fields), do: struct!(App.A, fields)
    end
    """
    |> to_source_file()
    |> run_check(EnforceKeys)
    |> assert_issues(fn issues ->
      assert length(issues) == 4
      assert Enum.any?(issues, &(&1.message =~ "App.Partial's struct leaves :name without"))
      assert Enum.any?(issues, &(&1.message =~ "App.Constructed's struct leaves :id, :name"))
    end)
  end

  test "an @enforce_keys it can't read is left alone" do
    ~S"""
    defmodule App.Computed do
      @fields [:id, :name]
      @enforce_keys @fields
      defstruct @fields
    end
    """
    |> to_source_file()
    |> run_check(EnforceKeys)
    |> refute_issues()
  end
end
