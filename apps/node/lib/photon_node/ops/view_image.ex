defmodule PhotonNode.Ops.ViewImage do
  @moduledoc """
  The `view_image` job (run by `PhotonNode.Ops.Job`): reads an
  image and returns it base64-encoded.

  Unlike upstream it doesn't resize: an image over the size limit fails with
  a note on making a smaller copy. Formats: PNG, JPEG, GIF, WebP.
  """

  @behaviour PhotonNode.Ops.Job

  alias PhotonCore.Operation
  alias PhotonNode.Ops.Image

  @source_limit 268_435_456

  @impl true
  @spec run(Operation.t()) :: Operation.t()
  def run(op) do
    {status, result} = view(op["state"]["path"], op["state"]["max_size"])
    Operation.advance(op, status, %{"result" => result})
  end

  defp view(path, max) do
    case read_image(path, max) do
      {:ok, encoded, info} -> {"completed", completed(encoded, info, path)}
      {:error, message} -> {"failed", %{"error" => message}}
    end
  end

  defp read_image(path, max) do
    with {:ok, %File.Stat{size: size, type: :regular}} <- File.stat(path),
         :ok <- within_source_limit(size),
         {:ok, bytes} <- File.read(path),
         {:ok, info} <- Image.inspect_bytes(bytes),
         encoded = Base.encode64(bytes),
         :ok <- size_ok(encoded, max, info) do
      {:ok, encoded, info}
    else
      failure -> read_error(failure, path)
    end
  end

  defp read_error({:ok, %File.Stat{type: type}}, path),
    do: {:error, "read image: #{path} is a #{type}, not a file"}

  defp read_error({:error, reason}, _path) when is_atom(reason),
    do: {:error, "read image: #{:file.format_error(reason)}"}

  defp read_error({:error, reason}, _path), do: {:error, reason}

  defp completed(encoded, info, path) do
    %{
      "content" => encoded,
      "mime" => info.mime,
      "width" => info.width,
      "height" => info.height,
      "path" => path
    }
  end

  defp within_source_limit(size) when size > @source_limit,
    do: {:error, "image source is #{size} bytes; source limit is #{@source_limit} bytes"}

  defp within_source_limit(_size), do: :ok

  defp size_ok(encoded, max, info) when byte_size(encoded) > max do
    dims = if info.width, do: " (#{info.width}x#{info.height})", else: ""

    {:error,
     "#{info.mime} image#{dims} needs #{byte_size(encoded)} base64 bytes; the limit is #{max}. " <>
       "Make a smaller copy (for example: convert in.png -resize 2000x2000 out.png) and view that."}
  end

  defp size_ok(_encoded, _max, _info), do: :ok
end
