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
      assert :allow = WardrikPolicy.decide(policy, "write_file", resources: ["notes/today.md"])

      assert :allow =
               WardrikPolicy.decide(policy, "books__create_bill", arguments: %{"amount" => 50})

      assert {:ask, "A bill this size needs a person."} =
               WardrikPolicy.decide(policy, "books__create_bill", arguments: %{"amount" => 9400})

      assert {:deny, "Mail stays in the company."} =
               WardrikPolicy.decide(policy, "email__send", arguments: %{"to" => "x@evil.example"})

      assert {:deny, "No shell."} = WardrikPolicy.decide(policy, "shell__exec")
    end

    test "a call no rule names follows the default", %{policy: policy} do
      assert :allow = WardrikPolicy.decide(policy, "write_file", resources: ["secrets/key"])

      assert {:deny, "write_file is not allowed for this agent."} =
               WardrikPolicy.decide(%{policy | default: :deny}, "write_file",
                 resources: ["secrets/key"]
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

  describe "explain/3" do
    test "names what caused the decision" do
      policy = WardrikPolicy.new!(allow: ["write_file(notes/*)"], deny: ["shell/*"])

      assert %WardrikPolicy.Decision{effect: :allow, rule: "write_file(notes/*)", cause: :rule} =
               WardrikPolicy.explain(policy, "write_file", resources: ["notes/a"])

      assert %WardrikPolicy.Decision{effect: :allow, rule: nil, cause: :no_rule} =
               WardrikPolicy.explain(policy, "web_search")

      assert %WardrikPolicy.Decision{effect: :allow, cause: :no_rule} =
               WardrikPolicy.explain(policy, "write_file", resources: ["notes/a", "secrets/key"])
    end
  end

  describe "several policies" do
    setup do
      org =
        WardrikPolicy.new!([allow: ["stripe/*"], ask: ["books/*"], deny: ["shell/*"]],
          name: "acme"
        )

      agent =
        WardrikPolicy.new!([deny: ["stripe/refund"], allow: ["shell/*", "refund_order"]],
          name: "books"
        )

      %{org: org, agent: agent}
    end

    test "any deny wins, so an agent's own policy can narrow its org's", %{org: org, agent: agent} do
      assert %WardrikPolicy.Decision{effect: :deny, policy: "books"} =
               WardrikPolicy.explain([org, agent], "stripe__refund")
    end

    test "an agent's own allow can't widen its org's", %{org: org, agent: agent} do
      assert %WardrikPolicy.Decision{effect: :deny, policy: "acme"} =
               WardrikPolicy.explain([org, agent], "shell__exec")

      assert %WardrikPolicy.Decision{effect: :ask, policy: "acme"} =
               WardrikPolicy.explain([agent, org], "books__create_bill")
    end

    test "an agent's own allow can't lift its org's default", %{agent: agent} do
      org = WardrikPolicy.new!([default: [read_only: :allow, else: :ask]], name: "acme")

      assert %WardrikPolicy.Decision{effect: :ask, policy: "acme", cause: :no_rule} =
               WardrikPolicy.explain([org, agent], "refund_order")

      assert %WardrikPolicy.Decision{effect: :allow} =
               WardrikPolicy.explain([org, agent], "list_issues", annotations: %{read_only: true})
    end

    test "no policies allow everything" do
      assert :allow = WardrikPolicy.decide([], "anything")
    end
  end

  describe "a default by annotation" do
    setup do
      policy =
        WardrikPolicy.new!(
          allow: ["refund_order"],
          default: [destructive: :deny, read_only: :allow, else: :ask]
        )

      %{policy: policy}
    end

    test "decides a call no rule names by the tool's annotations", %{policy: policy} do
      assert :allow = WardrikPolicy.decide(policy, "list", annotations: %{read_only: true})
      assert {:ask, _} = WardrikPolicy.decide(policy, "open_issue")

      assert {:ask, _} =
               WardrikPolicy.decide(policy, "open_issue", annotations: %{read_only: nil})

      assert {:deny, _} = WardrikPolicy.decide(policy, "drop", annotations: %{destructive: true})
    end

    test "a rule that names the call still decides it", %{policy: policy} do
      assert :allow = WardrikPolicy.decide(policy, "refund_order")
    end

    test "the strictest of the tool's annotations wins", %{policy: policy} do
      assert {:deny, _} =
               WardrikPolicy.decide(policy, "purge",
                 annotations: %{read_only: true, destructive: true}
               )
    end

    test "allows the rest unless else says" do
      policy = WardrikPolicy.new!(default: [read_only: :allow])

      assert :allow = WardrikPolicy.decide(policy, "anything")
    end

    test "reads from a file the same way" do
      {:ok, policy} =
        WardrikPolicy.decode(%{"default" => %{"read_only" => "allow", "else" => "ask"}})

      assert :allow = WardrikPolicy.decide(policy, "list", annotations: %{read_only: true})
      assert {:ask, _} = WardrikPolicy.decide(policy, "open_issue")
    end

    test "says what is wrong with a default it can't read" do
      assert {:error, "default gives read_only \"sometimes\", which is not allow, ask or deny"} =
               WardrikPolicy.decode(%{"default" => %{"read_only" => "sometimes"}})

      assert {:error, "default is allow, ask or deny" <> _} =
               WardrikPolicy.decode(%{"default" => "maybe"})
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
