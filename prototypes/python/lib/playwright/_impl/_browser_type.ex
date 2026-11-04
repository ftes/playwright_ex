# upstream: playwright/_impl/_browser_type.py (subset)
defmodule Playwright.Impl.BrowserType do
  use Playwright.Impl.Connection.ChannelOwner
  alias Playwright.Impl.Connection.{Channel, ChannelOwner}
  alias Playwright.Impl.Browser
  alias Playwright.Impl.Helper.TimeoutSettings
  import Playwright.Impl.Connection, only: [from_channel: 1]
  import Playwright.Impl.Helper, only: [locals_to_params: 1]

  # upstream: _browser_type.py:59
  def init(parent, type, guid, initializer) do
    self = ChannelOwner.init(Py.new(__MODULE__), parent, type, guid, initializer)
    Py.set(self, :_playwright, nil)
    self
  end

  # upstream: _browser_type.py:69
  def name(self), do: self[:_initializer]["name"]

  # upstream: _browser_type.py:73
  def executable_path(self), do: self[:_initializer]["executablePath"]

  # upstream: _browser_type.py:76
  def launch(self, opts \\ []) do
    params = locals_to_params(binding())
    params = normalize_launch_params(params)

    browser =
      from_channel(
        Channel.send(self[:_channel], "launch", &TimeoutSettings.launch_timeout/1, params)
      )

    Browser._connect_to_browser_type(
      browser,
      self,
      opts[:tracesDir] && to_string(opts[:tracesDir])
    )

    browser
  end

  # upstream: _browser_type.py:304
  def _prepare_browser_context_params(self, params) do
    params =
      if params[:noViewport],
        do: params |> Keyword.delete(:noViewport) |> Keyword.put(:noDefaultViewport, true),
        else: params

    params = Keyword.delete(params, :defaultBrowserType)

    # (extraHTTPHeaders, recordVideo*, storageState, colorScheme/reducedMotion/forcedColors/contrast
    #  "null" mapping, clientCertificates, httpCredentials omitted in prototype)
    params =
      if Keyword.has_key?(params, :acceptDownloads),
        do:
          Keyword.put(
            params,
            :acceptDownloads,
            if(params[:acceptDownloads], do: "accept", else: "deny")
          ),
        else: params

    params =
      Keyword.put(params, :selectorEngines, self[:_playwright][:selectors][:_selector_engines])

    params =
      Keyword.put(
        params,
        :testIdAttributeName,
        self[:_playwright][:selectors][:_test_id_attribute_name]
      )

    # Remove HAR options
    params =
      Keyword.drop(params, [
        :recordHarPath,
        :recordHarOmitContent,
        :recordHarUrlFilter,
        :recordHarMode,
        :recordHarContent
      ])

    params
  end

  # upstream: _browser_type.py:361
  def normalize_launch_params(params) do
    params =
      if Keyword.has_key?(params, :env),
        do:
          Keyword.put(
            params,
            :env,
            for({name, value} <- params[:env], do: %{"name" => name, "value" => to_string(value)})
          ),
        else: params

    params =
      cond do
        params[:ignoreDefaultArgs] == true ->
          params |> Keyword.put(:ignoreAllDefaultArgs, true) |> Keyword.delete(:ignoreDefaultArgs)

        params[:ignoreDefaultArgs] == false ->
          Keyword.delete(params, :ignoreDefaultArgs)

        true ->
          params
      end

    params =
      if Keyword.has_key?(params, :executablePath),
        do: Keyword.update!(params, :executablePath, &to_string/1),
        else: params

    params =
      if Keyword.has_key?(params, :downloadsPath),
        do: Keyword.update!(params, :downloadsPath, &to_string/1),
        else: params

    params =
      if Keyword.has_key?(params, :tracesDir),
        do: Keyword.update!(params, :tracesDir, &to_string/1),
        else: params

    params =
      if Keyword.has_key?(params, :artifactsDir),
        do: Keyword.update!(params, :artifactsDir, &to_string/1),
        else: params

    params
  end
end
