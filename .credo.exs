# 1:1 ports keep upstream names (`isConnected` -> `is_connected`) and control flow, so
# style checks that would reshape them are relaxed for the ported code only.
ported = [~r"lib/playwright_ex/(client|protocol)/"]
upstream_shaped = ported ++ [~r"lib/playwright_ex/runtime/", ~r"lib/playwright_ex/driver.ex"]

%{
  configs: [
    %{
      name: "default",
      files: %{included: ["lib/", "test/", "config/", "mix.exs"], excluded: [~r"/_build/", ~r"/deps/"]},
      checks: %{
        extra: [
          {Credo.Check.Readability.PredicateFunctionNames, files: %{excluded: ported}},
          {Credo.Check.Refactor.NegatedConditionsWithElse, files: %{excluded: ported}},
          {Credo.Check.Refactor.MatchInCondition, files: %{excluded: ported}},
          {Credo.Check.Refactor.CyclomaticComplexity, files: %{excluded: upstream_shaped}},
          {Credo.Check.Refactor.Nesting, files: %{excluded: upstream_shaped}}
        ]
      }
    }
  ]
}
