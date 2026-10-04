defmodule PhotonCredo.Check.CaptureTestLogsTest do
  use Credo.Test.Case

  alias PhotonCredo.Check.CaptureTestLogs

  test "a test helper that captures logs passes" do
    ~S"""
    ExUnit.start(exclude: [:slow], capture_log: true)
    """
    |> to_source_file("test/test_helper.exs")
    |> run_check(CaptureTestLogs)
    |> refute_issues()
  end

  test "a test helper that doesn't is reported" do
    ~S"""
    ExUnit.start(exclude: [:slow])
    """
    |> to_source_file("test/test_helper.exs")
    |> run_check(CaptureTestLogs)
    |> assert_issue()
  end

  test "a helper that doesn't start ExUnit, or configures it, passes" do
    ~S"""
    Code.require_file("checks.exs", __DIR__)
    """
    |> to_source_file("test/extra/test_helper.exs")
    |> run_check(CaptureTestLogs)
    |> refute_issues()

    ~S"""
    ExUnit.start()
    ExUnit.configure(capture_log: true)
    """
    |> to_source_file("test/test_helper.exs")
    |> run_check(CaptureTestLogs)
    |> refute_issues()
  end

  test "other files are not checked" do
    ~S"""
    ExUnit.start()
    """
    |> to_source_file("test/support/case.ex")
    |> run_check(CaptureTestLogs)
    |> refute_issues()
  end
end
