defmodule Photon.Provision.Lines do
  @moduledoc false
  # Collects command output, reporting each complete line as it arrives.
  defstruct log: nil, partial: "", all: []

  defimpl Collectable do
    def into(acc) do
      {acc,
       fn
         acc, {:cont, chunk} ->
           [partial | complete] = (acc.partial <> chunk) |> String.split("\n") |> Enum.reverse()
           complete = Enum.reverse(complete)
           Enum.each(complete, fn line -> if String.trim(line) != "", do: acc.log.(line) end)
           %{acc | partial: partial, all: acc.all ++ complete}

         acc, :done ->
           if String.trim(acc.partial) != "", do: acc.log.(acc.partial)
           %{acc | all: acc.all ++ [acc.partial], partial: ""}

         _acc, :halt ->
           :ok
       end}
    end
  end
end
