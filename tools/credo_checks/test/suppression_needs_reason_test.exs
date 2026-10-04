defmodule PhotonCredo.Check.SuppressionNeedsReasonTest do
  use Credo.Test.Case

  alias PhotonCredo.Check.SuppressionNeedsReason

  test "a credo:disable comment with a reason above passes" do
    ~S"""
    defmodule App.Wide do
      # The URL is the provider's and can't be wrapped.
      # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
      @url "https://example.com/a/very/long/path"
    end
    """
    |> to_source_file()
    |> run_check(SuppressionNeedsReason)
    |> refute_issues()
  end

  test "a credo:disable comment without a reason is reported" do
    ~S"""
    defmodule App.Wide do
      @doc false
      # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
      @url "https://example.com/a/very/long/path"
    end
    """
    |> to_source_file()
    |> run_check(SuppressionNeedsReason)
    |> assert_issue(fn issue -> assert issue.line_no == 3 end)
  end

  test "an @dialyzer attribute needs a reason above it" do
    ~S"""
    defmodule App.Recover do
      @dialyzer {:nowarn_function, recover: 1}
      def recover(record), do: record
    end
    """
    |> to_source_file()
    |> run_check(SuppressionNeedsReason)
    |> assert_issue()
  end

  test "an @dialyzer attribute with a reason passes" do
    ~S"""
    defmodule App.Recover do
      # Only a corrupt record reaches the default clause; see recover/1.
      @dialyzer {:nowarn_function, recover: 1}
      def recover(record), do: record
    end
    """
    |> to_source_file()
    |> run_check(SuppressionNeedsReason)
    |> refute_issues()
  end
end
