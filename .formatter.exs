# Used by "mix format"
[
  inputs: [
    "{mix,.formatter}.exs",
    "{config,test}/**/*.{ex,exs}",
    "lib/*.ex",
    "lib/mix/**/*.ex",
    "lib/playwright_ex/*.ex",
    "lib/playwright_ex/{runtime,transport}/**/*.ex"
  ],
  plugins: [Styler],
  subdirectories: ["lib/playwright_ex/client", "lib/playwright_ex/protocol"],
  line_length: 120
]
