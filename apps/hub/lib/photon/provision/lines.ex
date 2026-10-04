defmodule Photon.Provision.Lines do
  @moduledoc false

  # Functional core: no processes, no I/O.
  use Boundary, type: :strict, deps: []

  # Collects command output, reporting each complete line as it arrives.
  # While collecting, `all` holds the lines newest first; `:done` puts them
  # in order.
  defstruct log: nil, partial: "", all: []

  @type t :: %__MODULE__{
          log: (String.t() -> term()) | nil,
          partial: String.t(),
          all: [String.t()]
        }

  defimpl Collectable do
    @impl true
    def into(acc) do
      {acc,
       fn
         acc, {:cont, chunk} ->
           [partial | complete] = (acc.partial <> chunk) |> String.split("\n") |> Enum.reverse()
           Enum.each(Enum.reverse(complete), &report(acc.log, &1))
           %{acc | partial: partial, all: complete ++ acc.all}

         acc, :done ->
           report(acc.log, acc.partial)
           %{acc | all: Enum.reverse([acc.partial | acc.all]), partial: ""}

         _acc, :halt ->
           :ok
       end}
    end

    defp report(log, line), do: if(String.trim(line) != "", do: log.(line))
  end
end
