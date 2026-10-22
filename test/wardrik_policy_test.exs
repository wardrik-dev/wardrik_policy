defmodule WardrikPolicyTest do
  use ExUnit.Case, async: true

  doctest WardrikPolicy

  describe "decide/4" do
    setup do
      policy =
        WardrikPolicy.new!(
          allow: ["web_search", "write_file(notes/*)", "books/create_bill(amount < 1000)"],
          ask: %{"books/create_bill(amount >= 1000)" => "A bill this size needs a person."},
          deny: %{
            "shell/*" => "No shell.",
            "email/send(to != *@acme.com)" => "Mail stays in the company."
          }
        )

      %{policy: policy}
    end

    test "decides each call the way the rules name it", %{policy: policy} do
      assert :allow = WardrikPolicy.decide(policy, "web_search")
      assert :allow = WardrikPolicy.decide(policy, "write_file", subjects: ["notes/today.md"])

      assert :allow =
               WardrikPolicy.decide(policy, "books__create_bill", arguments: %{"amount" => 50})

      assert {:ask, "A bill this size needs a person."} =
               WardrikPolicy.decide(policy, "books__create_bill", arguments: %{"amount" => 9400})

      assert {:deny, "Mail stays in the company."} =
               WardrikPolicy.decide(policy, "email__send", arguments: %{"to" => "x@evil.example"})

      assert {:deny, "No shell."} = WardrikPolicy.decide(policy, "shell__exec")
    end

    test "a call no rule names follows the default", %{policy: policy} do
      assert :allow = WardrikPolicy.decide(policy, "write_file", subjects: ["secrets/key"])

      assert {:deny, "write_file is not allowed for this agent."} =
               WardrikPolicy.decide(%{policy | default: :deny}, "write_file",
                 subjects: ["secrets/key"]
               )
    end

    test "the strictest rule wins" do
      policy = WardrikPolicy.new!(allow: ["github/*"], deny: ["github/delete_*"])

      assert :allow = WardrikPolicy.decide(policy, "github__create_issue")
      assert {:deny, _} = WardrikPolicy.decide(policy, "github__delete_repo")
    end

    test "reads arguments the way a model writes them", %{policy: policy} do
      assert {:ask, _} =
               WardrikPolicy.decide(policy, "books__create_bill",
                 arguments: %{"amount" => "9400"}
               )

      assert {:ask, _} =
               WardrikPolicy.decide(policy, "books__create_bill",
                 arguments: %{"amount" => "$9,400"}
               )

      assert :allow = WardrikPolicy.decide(policy, "books__create_bill", arguments: %{})
    end
  end

  describe "decide/3 on a gated tool" do
    test "asks unless an allow rule names it" do
      policy = WardrikPolicy.new!(allow: ["refund_order"])

      assert :allow = WardrikPolicy.decide(policy, "refund_order", gated: true)

      assert {:ask, "open_issue can change something."} =
               WardrikPolicy.decide(policy, "open_issue", gated: true)
    end
  end

  describe "new!/1" do
    test "reads a policy written as a file writes it" do
      assert %WardrikPolicy{default: :ask, rules: [_]} =
               WardrikPolicy.new!(%{"deny" => ["shell/*"], "default" => "ask"})
    end

    test "says what is wrong with a policy it can't read" do
      assert_raise ArgumentError, ~r/maybe is not a setting/, fn ->
        WardrikPolicy.new!(maybe: ["web_search"])
      end

      assert_raise ArgumentError, ~r/never closes/, fn ->
        WardrikPolicy.new!(deny: ["books/*(amount > 5"])
      end

      assert_raise ArgumentError, ~r/YAML reads as a key/, fn ->
        WardrikPolicy.new!(%{"deny" => [%{"books/*(memo" => "x)"}]})
      end
    end
  end
end
