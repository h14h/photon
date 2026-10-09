defmodule PhotonWeb.FormParams do
  @moduledoc """
  What the pages' forms over plain maps share. Pure: each takes the
  params a form sent and returns what the page uses.
  """

  @doc """
  The form over `params`, named `as`, with `errors` (`%{field => message}`,
  as the contexts give them) under their fields.
  """
  @spec form(map(), atom(), %{optional(atom() | String.t()) => String.t()}) ::
          Phoenix.HTML.Form.t()
  def form(params, as, errors \\ %{}),
    do:
      Phoenix.Component.to_form(params,
        as: as,
        errors: Enum.map(errors, fn {k, v} -> {k, {v, []}} end)
      )

  @doc "`params` with a browser's line breaks (`\\r\\n`) in each text value made plain."
  @spec clean(map()) :: map()
  def clean(params) do
    Map.new(params, fn
      {key, value} when is_binary(value) -> {key, String.replace(value, "\r\n", "\n")}
      pair -> pair
    end)
  end

  @doc """
  The version a form loaded (its `version` param): a positive whole
  number, or 0 when it is missing or isn't one.
  """
  @spec version(map()) :: non_neg_integer()
  def version(params) do
    case Integer.parse(Map.get(params, "version", "")) do
      {version, ""} when version > 0 -> version
      _other -> 0
    end
  end
end
