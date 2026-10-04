defmodule PhotonCredo.Check.StructTypeTest do
  use Credo.Test.Case

  alias PhotonCredo.Check.StructType

  test "structs and schemas with a type pass" do
    ~S"""
    defmodule App.Point do
      defstruct x: 0, y: 0
      @type t :: %__MODULE__{x: integer(), y: integer()}
    end

    defmodule App.Token do
      defstruct [:ref]
      @opaque t :: %__MODULE__{ref: reference()}
    end

    defmodule App.User do
      use Ecto.Schema
      @type t :: %__MODULE__{}
      schema "users" do
        field :name, :string
      end
    end

    defmodule App.Helpers do
      def schema(name), do: name
    end
    """
    |> to_source_file()
    |> run_check(StructType)
    |> refute_issues()
  end

  test "a struct, exception or schema without a type is reported" do
    ~S"""
    defmodule App.Point do
      defstruct x: 0, y: 0
    end

    defmodule App.Oops do
      defexception [:message]
    end

    defmodule App.User do
      use Ecto.Schema
      schema "users" do
        field :name, :string
      end
    end
    """
    |> to_source_file()
    |> run_check(StructType)
    |> assert_issues(fn issues -> assert length(issues) == 3 end)
  end
end
