defmodule PhotonNode.Harness.Tools.Bash do
  @moduledoc "The Bash tool: one `shell` operation per call."

  @behaviour PhotonNode.Harness.Tools

  alias PhotonCore.Message
  alias PhotonNode.Harness.{Operation, Output, Tools}

  @impl true
  def name, do: "Bash"

  @impl true
  def definition do
    %{
      "name" => "Bash",
      "description" =>
        "Execute a shell command in background. Independent commands may be issued as parallel tool calls in one turn. Command child processes are killed when the shell exits.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "command" => %{"type" => "string", "description" => "The shell command to execute."},
          "max_output_length" => %{
            "type" => "integer",
            "description" =>
              "Maximum characters per output text field. Truncated text keeps its head and tail, around a marker stating how much was omitted, and path to the file with the complete stream. Defaults to 40000.",
            "minimum" => 1,
            "maximum" => 1_000_000,
            "default" => 40_000
          }
        },
        "required" => ["command"]
      }
    }
  end

  @impl true
  def translate(call, env) do
    with {:ok, args} <- decode(call["arguments"]),
         {:ok, limit} <- limit(args["max_output_length"]),
         {:ok, command} <- command(args, limit) do
      op = shell_operation(command, limit, env)
      {Tools.ok_status([op]), [op]}
    else
      {:error, message, limit} -> {Tools.error_status(message, limit), []}
      {:error, message} -> {Tools.error_status(message, Output.default_limit()), []}
    end
  end

  defp shell_operation(command, limit, env) do
    Operation.new(
      "shell",
      1,
      %{
        "input" => %{"command" => command, "shell" => env.shell, "directory" => env.workspace},
        "base_directory" => env.operations_dir,
        "phase" => "",
        "pgid" => 0,
        "exit_code" => nil,
        "result" => nil,
        "terminal_error" => "",
        "out_path" => "",
        "err_path" => ""
      },
      limit
    )
  end

  defp decode(args), do: Tools.decode_arguments(args, &decode_error/1)

  defp decode_error(:not_an_object), do: "decode Bash arguments: expected a JSON object"
  defp decode_error(error), do: "decode Bash arguments: " <> Exception.message(error)

  defp limit(nil), do: {:ok, Output.default_limit()}

  defp limit(n) when is_integer(n) and n > 1_000_000,
    do: {:error, "bash argument: max_output_length must not exceed 1000000"}

  defp limit(n) when is_integer(n) and n > 0, do: {:ok, n}

  defp limit(n) when is_integer(n),
    do: {:error, "bash argument: max_output_length must be a positive integer"}

  defp limit(_), do: {:error, "bash argument: decode max_output_length: expected an integer"}

  defp command(args, limit), do: check_command(Map.fetch(args, "command"), limit)

  defp check_command(:error, limit),
    do: {:error, ~s(bash argument "command" must be set), limit}

  defp check_command({:ok, nil}, limit),
    do: {:error, ~s(bash argument "command" must be a string), limit}

  defp check_command({:ok, command}, limit) when is_binary(command),
    do: check_nul(command, :binary.match(command, <<0>>), limit)

  defp check_command({:ok, _other}, limit),
    do: {:error, ~s(decode Bash argument "command": expected a string), limit}

  defp check_nul(command, :nomatch, _limit), do: {:ok, command}

  defp check_nul(_command, {offset, _length}, limit),
    do: {:error, ~s(bash argument "command" contains a NUL byte at offset #{offset}), limit}

  @impl true
  def format(%{"error" => error}, _ops) when error not in [nil, ""],
    do: [Message.text("Error: " <> error)]

  def format(_status, [op | _]), do: [Message.text(operation_text(op, Operation.terminal?(op)))]

  def format(_status, []), do: [Message.text("(no output)")]

  defp operation_text(op, true = _terminal), do: result_text(op)
  defp operation_text(_op, false), do: "Command is still running."

  defp result_text(%{"status" => status, "state" => state}) do
    lines = output_lines(state["result"], state, error_line(status, state))

    case Enum.reject(lines, &is_nil/1) do
      [] -> "(no output)"
      lines -> Enum.join(lines, "\n")
    end
  end

  # The command's output once it finished, or where it was captured, then the error line.
  defp output_lines(nil, state, error_line),
    do: [
      capture_line("Stdout capture: ", state["out_path"]),
      capture_line("Stderr capture: ", state["err_path"]),
      error_line
    ]

  defp output_lines(result, _state, error_line),
    do: [
      out_line(result["out"]),
      err_line(result["err"]),
      exit_line(result["exit_code"]),
      error_line
    ]

  defp out_line(""), do: nil
  defp out_line(out), do: out

  defp err_line(""), do: nil
  defp err_line(err), do: "Stderr:\n" <> err

  defp exit_line(0), do: nil
  defp exit_line(code), do: "Exit code: #{code}"

  defp capture_line(_label, ""), do: nil
  defp capture_line(label, path), do: label <> path

  defp error_line(_status, %{"terminal_error" => error}) when error not in [nil, ""],
    do: "Error: " <> error

  defp error_line("failed", _state), do: "Error: shell operation failed"
  defp error_line("canceled", _state), do: "Error: shell operation canceled"
  defp error_line(_status, _state), do: nil
end
