defmodule PhotonWeb.SkillText do
  @moduledoc """
  The words the skills pages use: where a skill is on ("On for Blip,
  Garden and machine mm1"), how it arrived ("Written here", "Pasted", "From
  github.com/..."), and its install notes as a list.

  Pure: the project names are passed in, so a page reads them once with
  the skills and these only format them.
  """

  alias Photon.Skills.Skill

  @typedoc "Where a skill is on, as `Photon.Skills` gives it."
  @type scope :: :blip | {:project, String.t()} | {:machine, String.t()}

  @doc ~S"""
  Where a skill is on, from its scopes (Blip first, then projects and
  machines) and the projects' names by ID: "On for Blip", "On for Blip
  and Garden", "On for Blip, Garden and machine mm1", or "Off
  everywhere". A machine reads "machine mm1", so it can't be taken for a
  project. A project missing from `names` is left out.
  """
  @spec scopes([scope()], %{String.t() => String.t()}) :: String.t()
  def scopes(scopes, names) do
    labels =
      Enum.flat_map(scopes, fn
        :blip -> ["Blip"]
        {:project, id} -> names |> Map.get(id) |> List.wrap()
        {:machine, id} -> ["machine " <> id]
      end)

    case labels do
      [] -> "Off everywhere"
      labels -> "On for " <> join(labels)
    end
  end

  defp join([one]), do: one
  defp join(labels), do: Enum.join(Enum.drop(labels, -1), ", ") <> " and " <> List.last(labels)

  @doc """
  How a skill arrived, for the Skills page: "Written here", "Pasted", or
  "From github.com/o/r/blob/main/pdf-forms/SKILL.md" (its link without the
  scheme). An origin it doesn't know reads "Installed".
  """
  @spec origin(Skill.t()) :: String.t()
  def origin(%Skill{origin: "written"}), do: "Written here"
  def origin(%Skill{origin: "pasted"}), do: "Pasted"

  def origin(%Skill{origin: "fetched", source_url: url}) when is_binary(url),
    do: "From " <> place(url)

  def origin(%Skill{}), do: "Installed"

  @doc ~S"""
  A link as the pages show it, without its scheme or a trailing slash:
  "https://github.com/o/r/" reads "github.com/o/r".
  """
  @spec place(String.t()) :: String.t()
  def place(url) do
    url
    |> String.replace(~r{\Ahttps?://}i, "")
    |> String.trim_trailing("/")
  end

  @doc ~S"""
  A skill's install notes, one per line as install kept them, without
  blank lines. None for a written skill.
  """
  @spec notes(String.t() | nil) :: [String.t()]
  def notes(nil), do: []

  def notes(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end
end
