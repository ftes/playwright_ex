defmodule PlaywrightEx.Browser do
  @moduledoc """
  Interact with a Playwright `Browser`.

  There is no official documentation, since this is considered Playwright internal.

  Reference: https://github.com/microsoft/playwright/blob/main/packages/playwright-core/src/client/browser.ts
  """

  alias PlaywrightEx.ChannelResponse
  alias PlaywrightEx.Connection

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      timeout: PlaywrightEx.Channel.timeout_opt(),
      accept_downloads: [
        type: :boolean,
        doc: "Whether to automatically download all the attachments. Defaults to `true`."
      ],
      base_url: [
        type: :string,
        doc:
          "When using `Page.goto/3`, `Page.route/3`, `Page.wait_for_url/3`, etc., it takes the base URL into consideration."
      ],
      bypass_csp: [
        type: :boolean,
        doc: "Toggles bypassing page's Content-Security-Policy. Defaults to `false`."
      ],
      color_scheme: [
        type: {:in, [:light, :dark, :no_preference, :no_override, :null]},
        doc: "Emulates `'prefers-colors-scheme'` media feature. Defaults to `:light`."
      ],
      device_scale_factor: [
        type: :float,
        doc: "Specify device scale factor (can be thought of as dpr). Defaults to `1`."
      ],
      extra_http_headers: [
        type: {:or, [{:map, {:or, [:atom, :string]}, :any}, {:list, :map}]},
        type_spec:
          quote(
            do:
              %{optional(String.t()) => String.t()}
              | [%{required(:name) => String.t(), required(:value) => String.t()}]
          ),
        type_doc: "`%{header => value} | [%{name: header, value: value}]`",
        doc: "An object containing additional HTTP headers to be sent with every request."
      ],
      http_credentials: [
        type: {:or, [:map, {:list, :map}]},
        type_spec:
          quote(
            do:
              %{
                required(:username) => String.t(),
                required(:password) => String.t(),
                optional(:origin) => String.t(),
                optional(:send) => :always | :unauthorized
              }
              | [
                  %{
                    required(:username) => String.t(),
                    required(:password) => String.t(),
                    optional(:origin) => String.t(),
                    optional(:send) => :always | :unauthorized
                  }
                ]
          ),
        type_doc: "`http_credential | [http_credential]`",
        doc: "Credentials for HTTP authentication. A credential map or a list of maps with `:username` and `:password`."
      ],
      ignore_https_errors: [
        type: :boolean,
        doc: "Whether to ignore HTTPS errors when sending network requests. Defaults to `false`."
      ],
      is_mobile: [
        type: :boolean,
        doc: "Whether the meta viewport tag is taken into account and touch events are enabled. Defaults to `false`."
      ],
      java_script_enabled: [
        type: :boolean,
        doc: "Whether or not to enable JavaScript in the context. Defaults to `true`."
      ],
      locale: [
        type: :string,
        doc: "Specify user locale, for example `en-GB`, `de-DE`, etc."
      ],
      user_agent: [
        type: :string,
        doc: "Specific user agent to use in this context."
      ],
      viewport: [
        type:
          {:or,
           [
             nil,
             map: [
               width: [
                 type: :pos_integer,
                 required: true,
                 doc: "Page width in CSS pixels."
               ],
               height: [
                 type: :pos_integer,
                 required: true,
                 doc: "Page height in CSS pixels."
               ]
             ]
           ]},
        type_spec:
          quote(
            do:
              nil
              | %{width: pos_integer(), height: pos_integer()}
          ),
        type_doc: "`nil | %{width: pos_integer(), height: pos_integer()}`",
        doc: "Sets a consistent viewport for each page. Set to `nil` to disable consistent viewport emulation."
      ]
    )

  @doc """
  Creates a new browser context. It won't share cookies/cache with other browser contexts.

  Reference: https://playwright.dev/docs/api/class-browser#browser-new-context

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type new_context_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec new_context(PlaywrightEx.guid(), [new_context_opt() | PlaywrightEx.unknown_opt()]) ::
          {:ok, %{guid: PlaywrightEx.guid(), tracing: %{guid: PlaywrightEx.guid()}}} | {:error, any()}
  def new_context(browser_id, opts \\ []) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)
    opts = prepare_new_context_opts(opts)

    connection
    |> Connection.send(%{guid: browser_id, method: :new_context, params: Map.new(opts)}, timeout)
    |> ChannelResponse.unwrap_create(:context, connection)
  end

  defp prepare_new_context_opts(opts) do
    opts
    |> prepare_viewport()
    |> prepare_http_credentials()
    |> prepare_accept_downloads()
    |> prepare_color_scheme()
    |> prepare_extra_http_headers()
  end

  defp prepare_viewport(opts) do
    if Keyword.get(opts, :viewport) == nil and Keyword.has_key?(opts, :viewport) do
      opts
      |> Keyword.delete(:viewport)
      |> Keyword.put(:no_default_viewport, true)
    else
      opts
    end
  end

  defp prepare_http_credentials(opts) do
    case Keyword.fetch(opts, :http_credentials) do
      {:ok, credentials} when is_map(credentials) ->
        Keyword.put(opts, :http_credentials, [credentials])

      {:ok, []} ->
        Keyword.delete(opts, :http_credentials)

      _ ->
        opts
    end
  end

  defp prepare_accept_downloads(opts) do
    case Keyword.fetch(opts, :accept_downloads) do
      {:ok, true} -> Keyword.put(opts, :accept_downloads, "accept")
      {:ok, false} -> Keyword.put(opts, :accept_downloads, "deny")
      :error -> opts
    end
  end

  defp prepare_color_scheme(opts) do
    case Keyword.fetch(opts, :color_scheme) do
      {:ok, :no_preference} -> Keyword.put(opts, :color_scheme, "no-preference")
      {:ok, value} when value in [:null, :no_override] -> Keyword.put(opts, :color_scheme, "no-override")
      :error -> opts
      _ -> opts
    end
  end

  defp prepare_extra_http_headers(opts) do
    case Keyword.fetch(opts, :extra_http_headers) do
      {:ok, headers} when is_map(headers) ->
        normalized = Enum.map(headers, fn {name, value} -> %{name: to_string(name), value: to_string(value)} end)
        Keyword.put(opts, :extra_http_headers, normalized)

      _ ->
        opts
    end
  end

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      timeout: PlaywrightEx.Channel.timeout_opt(),
      reason: [
        type: :string,
        doc: "The reason to be reported to the operations interrupted by the browser closure."
      ]
    )

  @doc """
  Closes the browser and all of its contexts.

  Reference: https://playwright.dev/docs/api/class-browser#browser-close

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type close_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec close(PlaywrightEx.guid(), [close_opt() | PlaywrightEx.unknown_opt()]) :: {:ok, any()} | {:error, any()}
  def close(browser_id, opts \\ []) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)

    connection
    |> Connection.send(%{guid: browser_id, method: :close, params: Map.new(opts)}, timeout)
    |> ChannelResponse.unwrap(& &1)
  end
end
