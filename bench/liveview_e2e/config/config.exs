import Config

config :logger, level: :info

# playwright.config.js: `use` and `outputDir`. Retries (CI only) and the monocart coverage
# reporter are left out, see DIFFICULTIES.md.
if config_env() == :test do
  config :playwright_ex, :test,
    context_options: [base_url: "http://localhost:4004/", ignore_https_errors: true],
    trace: :retain_on_failure,
    screenshot: :only_on_failure,
    output_dir: "test-results"
end
