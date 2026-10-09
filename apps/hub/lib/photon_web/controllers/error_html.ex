defmodule PhotonWeb.ErrorHTML do
  @moduledoc "Renders the endpoint's errors on HTML requests (see config/config.exs)."
  use PhotonWeb, :html

  # A plain text page from the template name: "404.html" is "Not Found".
  @spec render(String.t(), map()) :: String.t()
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
