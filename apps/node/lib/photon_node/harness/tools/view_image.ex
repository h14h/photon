defmodule PhotonNode.Harness.Tools.ViewImage do
  @moduledoc "The ViewImage tool: one `view_image` operation per call."

  @behaviour PhotonNode.Harness.Tools

  alias PhotonCore.Message
  alias PhotonNode.Harness.{Operation, Tools}

  @max_size 4_999_000

  @impl true
  def name, do: "ViewImage"

  @impl true
  def definition do
    %{
      "name" => "ViewImage",
      "description" => "View a local JPEG, PNG, GIF, or WebP image.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "Image file path, absolute or relative to the workspace."
          }
        },
        "required" => ["path"]
      }
    }
  end

  @impl true
  def translate(call, env) do
    with {:ok, args} <- decode(call["arguments"]),
         {:ok, path} <- path(args) do
      path = if Path.type(path) == :absolute, do: path, else: env.workspace <> "/" <> path

      op =
        Operation.new("view_image", 1, %{"path" => path, "max_size" => @max_size, "result" => nil})

      {Tools.ok_status([op]), [op]}
    else
      {:error, message} -> {Tools.error_status(message), []}
    end
  end

  defp decode(args),
    do:
      Tools.decode_arguments(args, fn _ ->
        "decode ViewImage arguments: expected a JSON object"
      end)

  defp path(%{"path" => path}) when is_binary(path) do
    cond do
      String.trim(path) == "" ->
        {:error, ~s(ViewImage argument "path" must be set)}

      match?({_, _}, :binary.match(path, <<0>>)) ->
        {:error, ~s(ViewImage argument "path" contains a NUL byte)}

      true ->
        {:ok, path}
    end
  end

  defp path(_), do: {:error, ~s(ViewImage argument "path" must be set)}

  @impl true
  def format(%{"error" => error}, _ops) when error not in [nil, ""],
    do: [Message.text("Error: " <> error)]

  def format(_status, [%{"status" => "completed", "state" => %{"result" => result}} | _]) do
    details =
      Enum.reject(
        [
          result["width"] && "dimensions: #{result["width"]}x#{result["height"]}",
          "path: #{result["path"]}"
        ],
        &is_nil/1
      )

    [Message.image(result["mime"], result["content"]), Message.text(Enum.join(details, "; "))]
  end

  def format(_status, [%{"status" => status} = op | _]) when status in ["failed", "canceled"],
    do: [Message.text("Error: " <> failure(op, status))]

  def format(_status, _ops), do: [Message.text("Image is still loading.")]

  # The operation snapshot's shape is the session log's, so it's read as stored.
  defp failure(%{"state" => %{"result" => %{"error" => error}}}, _status)
       when error not in [nil, false],
       do: error

  defp failure(_op, status), do: "view-image operation #{status}"

  @doc "The largest base64 image a result may carry."
  @spec max_size() :: pos_integer()
  def max_size, do: @max_size
end
