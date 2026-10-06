defmodule PhotonWeb.TimeComponentsTest do
  @moduledoc """
  Times the browser converts to the owner's zone: the server's part is the
  ISO time in UTC, a UTC fallback, and the hidden field a form reads.
  """

  use Photon.Case, async: true

  import Phoenix.LiveViewTest

  alias PhotonWeb.TimeComponents

  defp html(component, assigns),
    do: LazyHTML.from_fragment(render_component(component, assigns))

  defp attr(html, selector, name),
    do: html |> LazyHTML.query(selector) |> LazyHTML.attribute(name)

  test "local_time/1 renders the ISO time for the hook and a UTC fallback" do
    html =
      html(&TimeComponents.local_time/1,
        id: "next",
        at: ~U[2026-10-08 14:00:07.123456Z]
      )

    assert attr(html, "time#next", "datetime") == ["2026-10-08T14:00:07Z"]
    assert attr(html, "time#next", "phx-hook") == ["PhotonWeb.TimeComponents.LocalTime"]
    assert attr(html, "time#next", "data-format") == ["datetime"]
    assert html |> LazyHTML.query("time#next") |> LazyHTML.text() == "Oct 8, 14:00 UTC"
  end

  test "local_datetime_input/1 renders the local input and the hidden UTC field with its errors" do
    form =
      Phoenix.Component.to_form(%{"at" => "2026-10-08T14:00:00.000Z"},
        as: :schedule,
        errors: [at: {"Pick a time in the future.", []}]
      )

    html =
      html(&TimeComponents.local_datetime_input/1,
        id: "schedule-at",
        field: form[:at],
        label: "When"
      )

    assert attr(html, "input#schedule-at", "type") == ["hidden"]
    assert attr(html, "input#schedule-at", "name") == ["schedule[at]"]
    assert attr(html, "input#schedule-at", "value") == ["2026-10-08T14:00:00.000Z"]

    assert attr(html, "input#schedule-at-local", "type") == ["datetime-local"]
    assert attr(html, "input#schedule-at-local", "name") == []
    assert attr(html, "input#schedule-at-local", "data-utc") == ["2026-10-08T14:00:00.000Z"]
    assert attr(html, "input#schedule-at-local", "phx-update") == ["ignore"]
    assert attr(html, "input#schedule-at-local", "data-invalid") == ["true"]
    assert attr(html, "label", "for") == ["schedule-at-local"]
    assert LazyHTML.text(html) =~ "Pick a time in the future."
  end
end
