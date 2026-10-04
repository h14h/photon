defmodule PhotonCredo.Check.DialyzerIgnoreReasonsTest do
  use Credo.Test.Case

  alias PhotonCredo.Check.DialyzerIgnoreReasons

  test "entries under a reason comment pass" do
    ~S"""
    # Dialyzer findings that are not bugs, each with the reason.
    [
      # Millisecond arithmetic Dialyzer can't see is integer.
      {"lib/a.ex", :missing_range},
      {"lib/b.ex", :missing_range},

      # JS structs are opaque, but these wrap functions that return them.
      {"lib/c.ex", :contract_with_opaque}
    ]
    """
    |> to_source_file(".dialyzer_ignore.exs")
    |> run_check(DialyzerIgnoreReasons)
    |> refute_issues()
  end

  test "an entry without a reason is reported, and the header covers none" do
    ~S"""
    # Dialyzer findings that are not bugs, each with the reason.
    [
      {"lib/a.ex", :missing_range},
      # A reason for the next one only.
      {"lib/b.ex", :missing_range},

      {"lib/c.ex", :unmatched_return}
    ]
    """
    |> to_source_file(".dialyzer_ignore.exs")
    |> run_check(DialyzerIgnoreReasons)
    |> assert_issues(fn issues ->
      assert issues |> Enum.map(& &1.line_no) |> Enum.sort() == [3, 7]
    end)
  end

  test "other files are not checked" do
    ~S"""
    [
      {"not", :an_ignore_file}
    ]
    """
    |> to_source_file("lib/app/data.exs")
    |> run_check(DialyzerIgnoreReasons)
    |> refute_issues()
  end
end
