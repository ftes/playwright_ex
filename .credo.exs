# Code shaped after upstream, and the facade generated from api.json, keeps its names
# (`isConnected` -> `is_connected`) and control flow, so checks that would reshape it are
# relaxed there only.
upstream_shaped = [
  ~r"lib/playwright_ex/(api|client|isomorphic|matchers|protocol|runtime)/",
  ~r"lib/playwright_ex/driver.ex",
  ~r"test/support/test_server.ex"
]

%{
  configs: [
    %{
      name: "default",
      files: %{included: ["lib/", "test/", "config/", "mix.exs"], excluded: [~r"/_build/", ~r"/deps/"]},
      checks: %{
        extra: [
          {Credo.Check.Readability.PredicateFunctionNames, files: %{excluded: upstream_shaped}},
          {Credo.Check.Refactor.NegatedConditionsWithElse, files: %{excluded: upstream_shaped}},
          {Credo.Check.Refactor.MatchInCondition, files: %{excluded: upstream_shaped}},
          {Credo.Check.Refactor.CyclomaticComplexity, files: %{excluded: upstream_shaped}},
          {Credo.Check.Refactor.Nesting, files: %{excluded: upstream_shaped}}
        ]
      }
    }
  ]
}
