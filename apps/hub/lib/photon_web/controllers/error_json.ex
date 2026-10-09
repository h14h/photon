defmodule PhotonWeb.ErrorJSON do
  @moduledoc "Renders the endpoint's errors on JSON requests (see config/config.exs)."

  # The status message from the template name: "404.json" is "Not Found".
  @spec render(String.t(), map()) :: %{errors: %{detail: String.t()}}
  def render(template, _assigns) do
    %{errors: %{detail: Phoenix.Controller.status_message_from_template(template)}}
  end
end
