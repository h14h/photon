defmodule Photon.Durable.SubmissionTest do
  use Photon.Case, async: true

  alias Photon.Durable.Submission

  defp from(source), do: %Submission{content: %{"parts" => [], "source" => source}}

  describe "background?/1" do
    test "is true for a schedule's firing, a signal and a relayed answer" do
      for kind <- ~w(routine signal answer) do
        assert Submission.background?(from(%{"kind" => kind})), kind
      end
    end

    test "is false for what someone typed or sent, and for no source" do
      for kind <- ~w(user blip follow_up) do
        refute Submission.background?(from(%{"kind" => kind})), kind
      end

      refute Submission.background?(from(nil))
      refute Submission.background?(%Submission{content: %{"parts" => []}})
      refute Submission.background?(%Submission{content: nil})
    end
  end
end
