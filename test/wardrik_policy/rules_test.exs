defmodule WardrikPolicy.RulesTest do
  use ExUnit.Case, async: true

  defp decide(rules, name, arguments) do
    rules |> WardrikPolicy.new!() |> WardrikPolicy.decide(name, arguments: arguments)
  end

  describe "conditions on arguments" do
    test "= matches text without case, with * for any run of characters" do
      rules = [deny: ["email/send(to = *@EVIL.example)"]]

      assert {:deny, _} = decide(rules, "email__send", %{"to" => "x@evil.example"})
      assert :allow = decide(rules, "email__send", %{"to" => "x@acme.com"})
    end

    test "!= holds where = does not" do
      rules = [deny: ["email/send(to != *@acme.com)"]]

      assert :allow = decide(rules, "email__send", %{"to" => "maria@acme.com"})
      assert {:deny, _} = decide(rules, "email__send", %{"to" => "x@evil.example"})
    end

    test "compares numbers, and text that reads as one" do
      rules = [deny: ["pay(amount > 100)"], ask: ["pay(amount >= 50)", "pay(fee <= 1)"]]

      assert {:deny, _} = decide(rules, "pay", %{"amount" => " 600.5 "})
      assert {:ask, _} = decide(rules, "pay", %{"amount" => 50})
      assert {:ask, _} = decide(rules, "pay", %{"fee" => 0.5})
      assert :allow = decide(rules, "pay", %{"amount" => 10, "fee" => 2})
      assert :allow = decide([deny: ["pay(amount < 0)"]], "pay", %{"amount" => 5})
    end

    test "= with a number compares as a number" do
      rules = [ask: ["pay(amount = 500)"]]

      assert {:ask, _} = decide(rules, "pay", %{"amount" => "500.0"})
      assert {:ask, _} = decide(rules, "pay", %{"amount" => 500})
      assert :allow = decide(rules, "pay", %{"amount" => 501})
    end

    test "a quoted value may hold commas and keeps its spaces" do
      rules = [deny: [~s|books/*(memo = "rent, march")|]]

      assert {:deny, _} = decide(rules, "books__pay", %{"memo" => "Rent, March"})
      assert :allow = decide(rules, "books__pay", %{"memo" => "rent"})
    end

    test "a comma means every condition must hold" do
      rules = [deny: ["bank/transfer(amount > 5000, currency = USD)"]]

      assert {:deny, _} =
               decide(rules, "bank__transfer", %{"amount" => 6000, "currency" => "usd"})

      assert :allow = decide(rules, "bank__transfer", %{"amount" => 6000, "currency" => "EUR"})
    end

    test "a dotted path reaches into nested arguments and lists" do
      rules = [deny: ["books/*(vendor.name = Acme*)"], allow: ["books/*(lines.amount < 100)"]]

      assert {:deny, _} = decide(rules, "books__pay", %{"vendor" => %{"name" => "Acme Ltd"}})

      assert :allow =
               decide(rules, "books__pay", %{"lines" => [%{"amount" => 5}, %{"amount" => 9}]})
    end

    test "a list matches an allow only where every item does, and a deny where any does" do
      allow = [allow: ["tag(labels = bug)"], default: :deny]
      deny = [deny: ["tag(labels = secret)"]]

      assert :allow = decide(allow, "tag", %{"labels" => ["bug", "BUG"]})
      assert {:deny, _} = decide(allow, "tag", %{"labels" => ["bug", "feature"]})
      assert {:deny, _} = decide(deny, "tag", %{"labels" => ["bug", "secret"]})
      assert :allow = decide(deny, "tag", %{"labels" => []})
    end

    test "booleans compare as text" do
      assert {:deny, _} = decide([deny: ["deploy(force = true)"]], "deploy", %{"force" => true})
      assert :allow = decide([deny: ["deploy(force != true)"]], "deploy", %{"force" => true})
    end

    test "a missing or null argument matches no condition" do
      rules = [deny: ["pay(amount > 1000)", "pay(to != *@acme.com)"]]

      assert :allow = decide(rules, "pay", %{})
      assert :allow = decide(rules, "pay", %{"amount" => nil})
    end

    test "an argument that can't be checked may hold: an ask or deny applies, an allow doesn't" do
      assert {:deny, _} = decide([deny: ["pay(amount > 1000)"]], "pay", %{"amount" => true})
      assert {:deny, _} = decide([deny: ["pay(to = x)"]], "pay", %{"to" => %{"id" => 1}})
      assert {:deny, _} = decide([deny: ["pay(to.id = 1)"]], "pay", %{"to" => "x"})

      assert {:deny, _} =
               decide([allow: ["pay(amount < 10)"], default: :deny], "pay", %{"amount" => "$5"})
    end
  end

  describe "what a call acts on" do
    test "an allow covers a call only where it names every resource" do
      policy = WardrikPolicy.new!(allow: ["write_file(notes/*)"], default: :deny)

      assert :allow =
               WardrikPolicy.decide(policy, "write_file", resources: ["notes/a", "notes/b"])

      assert {:deny, _} =
               WardrikPolicy.decide(policy, "write_file", resources: ["notes/a", "secrets/key"])

      assert {:deny, _} = WardrikPolicy.decide(policy, "write_file")
    end
  end

  describe "rules it can't read" do
    test "say what is wrong" do
      for {rules, message} <- [
            {[deny: ["pay(amount: 5)"]], ~r/a condition on a value is amount = 5/},
            {[deny: ["pay(amount == 5)"]], ~r/a condition on a value is amount = 5/},
            {[deny: ["pay(amount > lots)"]], ~r/which is not a number/},
            {[deny: ["pay(notes/*, amount > 5)"]], ~r/one or the other/},
            {[deny: [~s|pay(memo = "a"b")|]], ~r/not one value in double quotes/},
            {[deny: ["pay(memo = )"]], ~r/gives memo no value/},
            {[deny: [~s|pay(memo = a"b)|]], ~r/quoted whole/},
            {[deny: ["pay(a)b"]], ~r/goes in parentheses after the tool/},
            {[deny: ["pay)"]], ~r/closes a parenthesis it never opens/},
            {[deny: [1]], ~r/is not a tool pattern/},
            {[deny: %{"pay" => 1}], ~r/a message that is not text/},
            {[deny: "pay"], ~r/is a list of tool patterns/},
            {[default: "sometimes"], ~r/default is allow, ask or deny/}
          ] do
        assert_raise ArgumentError, message, fn -> WardrikPolicy.new!(rules) end
      end
    end

    test "decode/1 takes a map" do
      assert {:error, _message} = WardrikPolicy.decode([:deny])
    end
  end
end
