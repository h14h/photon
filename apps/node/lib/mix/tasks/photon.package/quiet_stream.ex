defmodule Mix.Tasks.Photon.Package.QuietStream do
  @moduledoc false

  use Boundary, classify_to: PhotonNode

  # Passes build output through, minus Burrito's per-file progress counter.
  defstruct []

  @type t :: %__MODULE__{}

  defimpl Collectable do
    @impl true
    def into(stream) do
      {stream,
       fn
         stream, {:cont, chunk} ->
           IO.write(String.replace(chunk, ~r/info: 🔍 Files Packed: \d+/u, ""))
           stream

         stream, _ ->
           stream
       end}
    end
  end
end
