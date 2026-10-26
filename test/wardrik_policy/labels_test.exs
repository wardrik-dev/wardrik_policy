defmodule WardrikPolicy.LabelsTest do
  use ExUnit.Case, async: true

  alias WardrikPolicy.Decision

  @gated %{gated: true}
  @outside ["outside"]

  defp explain(rules, name, opts),
    do: rules |> WardrikPolicy.new!() |> WardrikPolicy.explain(name, opts)

  defp decide(rules, name, opts),
    do: rules |> WardrikPolicy.new!() |> WardrikPolicy.decide(name, opts)

  test "a gated call a rule allows asks once the run has read content from outside" do
    rules = [allow: ["linear/*"]]

    assert %Decision{effect: :ask, cause: :label, rule: "linear/*", message: message} =
             explain(rules, "linear__create_issue", annotations: @gated, labels: @outside)

    assert message ==
             "linear/create_issue is allowed, but this run has read content from outside, " <>
               "which may be what asked for it."

    assert :allow = decide(rules, "linear__create_issue", annotations: @gated, labels: [])
    assert :allow = decide(rules, "linear__list_issues", labels: @outside)
  end

  test "allow_after allows by name, before and after its label" do
    rules = [allow: ["linear/*"], allow_after: %{"outside" => ["github/add_labels"]}]
    opts = [annotations: @gated, labels: @outside]

    assert :allow = decide(rules, "github__add_labels", opts)
    assert :allow = decide(rules, "github__add_labels", annotations: @gated)
  end

  test "an ask or deny still wins over allow_after" do
    rules = [
      allow_after: %{"outside" => ["github/*"]},
      ask: ["github/merge"],
      deny: ["github/delete_repo"]
    ]

    opts = [annotations: @gated, labels: @outside]
    assert {:ask, "github/merge needs your approval."} = decide(rules, "github__merge", opts)
    assert {:deny, _message} = decide(rules, "github__delete_repo", opts)
  end

  test "a label allow_after names holds as outside does, and one no rule names holds nothing" do
    rules = [allow: ["books/*"], allow_after: %{"payroll" => ["books/read_*"]}]

    assert {:ask, "books/pay is allowed, but this run has read content labelled payroll" <> _} =
             decide(rules, "books__pay", annotations: @gated, labels: ["payroll"])

    assert :allow = decide(rules, "books__read_ledger", annotations: @gated, labels: ["payroll"])
    assert :allow = decide(rules, "books__pay", annotations: @gated, labels: ["receipts"])
  end

  test "allow_after covers a call only where it names every resource" do
    rules = [allow: ["write_file"], allow_after: %{"outside" => ["write_file(notes/*)"]}]
    opts = [annotations: @gated, labels: @outside]

    assert :allow = decide(rules, "write_file", [resources: ["notes/a.md"]] ++ opts)

    assert {:ask, _message} =
             decide(rules, "write_file", [resources: ["notes/a.md", "secrets/key"]] ++ opts)
  end

  test "a gated call only the default allows is the default's to decide" do
    assert :allow = decide([], "linear__create_issue", annotations: @gated, labels: @outside)
  end

  test "allow_after that doesn't read says why" do
    for {rules, message} <- [
          {[allow_after: ["github/*"]], ~r/allow_after is a map of label to tool patterns/},
          {[allow_after: %{"" => ["github/*"]}], ~r/which is not a label/},
          {[allow_after: %{"outside" => "github/*"}], ~r/is a list of tool patterns/}
        ] do
      assert_raise ArgumentError, message, fn -> WardrikPolicy.new!(rules) end
    end
  end
end
