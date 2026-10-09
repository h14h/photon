defmodule PhotonWeb.LiveHelpers do
  @moduledoc "Reading a LiveView's page in tests: after the store's announcements, and by DOM ID."

  # Test support sits outside the layering (compiled only for tests).
  use Boundary, top_level?: true, check: [in: false, out: false]

  import Phoenix.LiveViewTest, only: [render: 1]

  @doc """
  Renders `view` once the store has handled every commit made so far. The
  Store broadcasts inside a commit's call, so after this barrier the page
  has the announcements of the state the test waited for queued before the
  render.
  """
  def settled(view) do
    _state = :sys.get_state(Photon.Durable.Store)
    render(view)
  end

  @doc "The DOM IDs of the elements `selector` matches, in page order."
  def dom_ids(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.attribute("id") |> hd()))
  end
end
