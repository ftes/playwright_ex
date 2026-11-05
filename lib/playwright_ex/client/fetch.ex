defmodule PlaywrightEx.Client.Fetch do
  @upstream "packages/playwright-core/src/client/fetch.ts"
  @moduledoc """
  Port of the top-level functions of `#{@upstream}`. Its classes are modules named after them
  (`PlaywrightEx.Client.APIRequest`, `PlaywrightEx.Client.APIRequestContext`,
  `PlaywrightEx.Client.APIResponse`), in this file.

  Bytes vs strings (PLAN Decisions): `data` is a JS string when a binary, a `Buffer` as
  `{:binary, bytes}`. A `fs.ReadStream` is a `File.Stream`, a `FilePayload` a map with
  `name`, `mimeType` and `buffer` (a binary: its type is only `Buffer`).
  """

  def to_form_field(name, value) do
    cond do
      is_file_payload(value) ->
        payload = value
        if !is_binary(payload.buffer), do: raise("Unexpected buffer type of 'data.#{name}'")
        %{name: name, file: file_payload_to_json(payload)}

      is_binary(value) or is_number(value) or is_boolean(value) ->
        %{name: name, value: js_string(value)}

      true ->
        %{name: name, file: read_stream_to_json(value)}
    end
  end

  def is_json_parsable(value) do
    if !is_binary(value) do
      false
    else
      # JSON.parse(value); catch SyntaxError
      match?({:ok, _}, JSON.decode(value))
    end
  end

  # type ServerFilePayload = NonNullable<channels.FormField['file']>;

  def file_payload_to_json(payload) do
    %{
      name: payload.name,
      mimeType: payload.mimeType,
      buffer: payload.buffer
    }
  end

  def read_stream_to_json(%File.Stream{} = stream) do
    buffer = Enum.into(stream, <<>>)
    stream_path = stream.path

    %{
      name: Path.basename(stream_path),
      buffer: buffer
    }
  end

  def is_json_content_type(headers) do
    if !headers do
      false
    else
      case Enum.find(headers, fn %{name: name} -> String.downcase(name) == "content-type" end) do
        %{value: value} -> value == "application/json"
        nil -> false
      end
    end
  end

  def object_to_array(map) do
    if !map do
      nil
    else
      for {name, value} <- map, value != nil, do: %{name: to_string(name), value: js_string(value)}
    end
  end

  def is_file_payload(value) do
    is_map(value) and !is_struct(value) and !!(value[:name] && value[:mimeType] && value[:buffer])
  end

  # JS String(value) for strings, numbers and booleans.
  defp js_string(value) when is_binary(value), do: value
  defp js_string(value) when is_float(value) and value == trunc(value), do: Integer.to_string(trunc(value))
  defp js_string(value), do: to_string(value)
end

defmodule PlaywrightEx.Client.APIRequest do
  @upstream "packages/playwright-core/src/client/fetch.ts"
  @moduledoc "Port of `APIRequest` in `#{@upstream}`: a runtime object (its `_contexts` set lives in the loop's heap)."
  import PlaywrightEx.Runtime.Heap

  alias PlaywrightEx.Client.APIRequestContext
  alias PlaywrightEx.Client.BrowserContext
  alias PlaywrightEx.Client.ChannelOwner
  alias PlaywrightEx.Client.TimeoutSettings
  alias PlaywrightEx.Isomorphic.Headers

  defstruct [:guid, :loop, :heap]

  def new(playwright) do
    this = new_object(__MODULE__)
    put(this, :_playwright, playwright)
    put(this, :_contexts, [])
    this
  end

  def new_context(this, options \\ %{}) do
    options = Map.merge(%{}, options || %{})
    # await this._playwright._instrumentation.runBeforeCreateRequestContext(options);  -- not ported: instrumentation
    storage_state =
      if is_binary(options[:storageState]),
        do: JSON.decode!(File.read!(options.storageState)),
        else: options[:storageState]

    playwright = get(this, :_playwright)

    context =
      APIRequestContext.from(
        ChannelOwner.channel_call(
          playwright,
          :newRequest,
          Map.merge(options, %{
            extraHTTPHeaders:
              if(options[:extraHTTPHeaders], do: Headers.headers_object_to_array(options.extraHTTPHeaders)),
            storageState: storage_state,
            # We do not expose tracesDir in the API, so do not allow options to accidentally override it.
            tracesDir: get(playwright, :_defaultLaunchOptions)[:tracesDir],
            clientCertificates: BrowserContext.to_client_certificates_protocol(options[:clientCertificates]),
            httpCredentials: BrowserContext.to_http_credentials_protocol(options[:httpCredentials])
          }),
          TimeoutSettings.k_no_timeout()
        ).request
      )

    set_add(this, :_contexts, context)
    put(context, :_request, this)

    TimeoutSettings.set_default_timeout(
      get(context, :_timeoutSettings),
      if(options[:timeout] != nil, do: options.timeout, else: get(playwright, :_defaultContextTimeout))
    )

    put(get(context, :tracing), :_tracesDir, get(playwright, :_defaultLaunchOptions)[:tracesDir])
    # await context._instrumentation.runAfterCreateRequestContext(context);  -- not ported: instrumentation
    context
  end
end

defmodule PlaywrightEx.Client.APIRequestContext do
  @upstream "packages/playwright-core/src/client/fetch.ts"
  @moduledoc "Port of `APIRequestContext` in `#{@upstream}`."
  use PlaywrightEx.Client.ChannelOwner

  # `put/3` is an HTTP method here: heap writes are `Heap.put/3`.
  import PlaywrightEx.Runtime.Heap, except: [put: 3]

  alias PlaywrightEx.Client.APIResponse
  alias PlaywrightEx.Client.ClientHelper
  alias PlaywrightEx.Client.Errors
  alias PlaywrightEx.Client.Fetch
  alias PlaywrightEx.Client.FileUtils
  alias PlaywrightEx.Client.Network
  alias PlaywrightEx.Client.Request
  alias PlaywrightEx.Client.Tracing
  alias PlaywrightEx.Isomorphic.Headers
  alias PlaywrightEx.Runtime.Heap

  def from(channel) do
    channel
  end

  def new(parent, type, guid, initializer) do
    this = ChannelOwner.new(__MODULE__, parent, type, guid, initializer)
    Heap.put(this, :tracing, Tracing.from(initializer.tracing))
    Heap.put(this, :_timeoutSettings, TimeoutSettings.new())
    this
  end

  # readonly properties
  def tracing(this), do: get(this, :tracing)

  # [Symbol.asyncDispose]  -- not ported: await using

  def dispose(this, options \\ %{}) do
    options = options || %{}
    Heap.put(this, :_closeReason, options[:reason])
    # await this._instrumentation.runBeforeCloseRequestContext(this);  -- not ported: instrumentation
    Tracing._export_all_hars(get(this, :tracing))

    try do
      channel_call(this, :dispose, options, TimeoutSettings.k_no_timeout())
      Tracing._reset_stack_counter(get(this, :tracing))
      if request = get(this, :_request), do: set_delete(request, :_contexts, this)
      nil
    rescue
      e -> if Errors.is_target_closed_error(e), do: nil, else: reraise(e, __STACKTRACE__)
    end
  end

  def cookies(this, urls \\ nil) do
    urls = if !urls, do: [], else: urls
    urls = if is_binary(urls), do: [urls], else: urls
    channel_call(this, :cookies, %{urls: urls}, TimeoutSettings.k_no_timeout()).cookies
  end

  def add_cookies(this, cookies) do
    channel_call(this, :addCookies, %{cookies: cookies}, TimeoutSettings.k_no_timeout())
    nil
  end

  def clear_cookies(this, options \\ %{}) do
    channel_call(this, :clearCookies, Network.to_clear_cookies_params(options || %{}), TimeoutSettings.k_no_timeout())
    nil
  end

  # No default for `options`: `get/2` and `put/3` are heap functions.
  def delete(this, url, options) do
    fetch(this, url, Map.merge(options || %{}, %{method: "DELETE"}))
  end

  def head(this, url, options) do
    fetch(this, url, Map.merge(options || %{}, %{method: "HEAD"}))
  end

  def get(this, url, options) do
    fetch(this, url, Map.merge(options || %{}, %{method: "GET"}))
  end

  def patch(this, url, options) do
    fetch(this, url, Map.merge(options || %{}, %{method: "PATCH"}))
  end

  def post(this, url, options) do
    fetch(this, url, Map.merge(options || %{}, %{method: "POST"}))
  end

  def put(this, url, options) do
    fetch(this, url, Map.merge(options || %{}, %{method: "PUT"}))
  end

  def fetch(this, url_or_request, options \\ %{}) do
    url = if is_binary(url_or_request), do: url_or_request
    request = if !is_binary(url_or_request), do: url_or_request
    _inner_fetch(this, Map.merge(%{url: url, request: request}, options || %{}))
  end

  def _inner_fetch(this, options \\ %{}) do
    _wrap_api_call(this, fn _ ->
      if get(this, :_closeReason), do: raise(Errors.TargetClosedError.new(get(this, :_closeReason)))
      assert(options[:request] || is_binary(options[:url]), "First argument must be either URL string or Request")

      assert(
        if(options[:data] == nil, do: 0, else: 1) + if(options[:form] == nil, do: 0, else: 1) +
          if(options[:multipart] == nil, do: 0, else: 1) <= 1,
        "Only one of 'data', 'form' or 'multipart' can be specified"
      )

      assert(
        options[:maxRedirects] == nil or options.maxRedirects >= 0,
        "'maxRedirects' must be greater than or equal to '0'"
      )

      assert(
        options[:maxRetries] == nil or options.maxRetries >= 0,
        "'maxRetries' must be greater than or equal to '0'"
      )

      url = if options[:url] != nil, do: options.url, else: Request.url(options.request)
      method = options[:method] || (options[:request] && Request.method(options.request))
      # URLSearchParams  -- not ported: no Elixir counterpart (a map or a string)
      encoded_params = if is_binary(options[:params]), do: options.params
      # Cannot call allHeaders() here as the request may be paused inside route handler.
      headers_obj = options[:headers] || (options[:request] && Request.headers(options.request))
      headers = if headers_obj, do: Headers.headers_object_to_array(headers_obj)

      {json_data, form_data, multipart_data, post_data_buffer} =
        cond do
          options[:data] != nil ->
            data = options.data

            cond do
              is_binary(data) ->
                if Fetch.is_json_content_type(headers),
                  do:
                    {if(Fetch.is_json_parsable(data), do: data, else: ClientHelper.json_stringify(data)), nil, nil, nil},
                  else: {nil, nil, nil, data}

              match?({:binary, _}, data) ->
                {nil, nil, nil, elem(data, 1)}

              # typeof null === 'object'
              data == :null or is_map(data) or is_list(data) or is_number(data) or is_boolean(data) ->
                {ClientHelper.json_stringify(data), nil, nil, nil}

              true ->
                raise "Unexpected 'data' type"
            end

          options[:form] ->
            # FormData  -- not ported: no Elixir counterpart
            {nil, Fetch.object_to_array(options.form), nil, nil}

          options[:multipart] ->
            # FormData  -- not ported: no Elixir counterpart
            # Convert file-like values to ServerFilePayload structs.
            {nil, nil, for({name, value} <- options.multipart, do: Fetch.to_form_field(to_string(name), value)), nil}

          true ->
            {nil, nil, nil, nil}
        end

      post_data_buffer =
        if post_data_buffer == nil and json_data == nil and form_data == nil and multipart_data == nil,
          do: (options[:request] && Request.post_data_buffer(options.request)) || nil,
          else: post_data_buffer

      # const fixtures = { __testHookLookup: (options as any).__testHookLookup };  -- not ported: in-process test hook
      result =
        channel_call(
          this,
          :fetch,
          %{
            url: url,
            params: if(is_map(options[:params]), do: Fetch.object_to_array(options.params)),
            encodedParams: encoded_params,
            method: method,
            headers: headers,
            postData: post_data_buffer,
            jsonData: json_data,
            formData: form_data,
            multipartData: multipart_data,
            failOnStatusCode: options[:failOnStatusCode],
            ignoreHTTPSErrors: options[:ignoreHTTPSErrors],
            maxRedirects: options[:maxRedirects],
            maxRetries: options[:maxRetries]
          },
          TimeoutSettings.timeout(get(this, :_timeoutSettings), options)
        )

      APIResponse.new(this, result.response)
    end)
  end

  def storage_state(this, options \\ %{}) do
    options = options || %{}

    state =
      channel_call(
        this,
        :storageState,
        %{indexedDB: options[:indexedDB], opfs: options[:opfs]},
        TimeoutSettings.k_no_timeout()
      )

    if options[:path] do
      FileUtils.mkdir_if_needed(options.path)
      # JSON.stringify(state, undefined, 2)  -- compact: Elixir's JSON has no indentation
      File.write!(options.path, JSON.encode!(state))
    end

    state
  end

  # isomorphic/assert.ts
  defp assert(value, message), do: if(!value, do: raise(message))
end

defmodule PlaywrightEx.Client.APIResponse do
  @upstream "packages/playwright-core/src/client/fetch.ts"
  @moduledoc "Port of `APIResponse` in `#{@upstream}`: no mutable state, a plain struct."
  import PlaywrightEx.Client.ChannelOwner, only: [channel_call: 4]

  alias PlaywrightEx.Client.ChannelOwner
  alias PlaywrightEx.Client.ClientHelper
  alias PlaywrightEx.Client.Errors
  alias PlaywrightEx.Client.RawHeaders
  alias PlaywrightEx.Client.TimeoutSettings

  defstruct [:_initializer, :_headers, :_request, _apiName: "APIResponse"]

  # Elixir only: `inspect(response)` is upstream's `util.inspect` (`inspect.custom`).
  defimpl Inspect do
    def inspect(this, _opts), do: PlaywrightEx.Client.APIResponse._inspect(this)
  end

  def new(context, initializer) do
    %__MODULE__{
      _request: context,
      _initializer: initializer,
      _headers: RawHeaders.new(initializer.headers)
    }
  end

  def ok(this) do
    this._initializer.status >= 200 and this._initializer.status <= 299
  end

  def url(this) do
    this._initializer.url
  end

  def status(this) do
    this._initializer.status
  end

  def status_text(this) do
    this._initializer.statusText
  end

  def headers(this) do
    RawHeaders.headers(this._headers)
  end

  def headers_array(this) do
    RawHeaders.headers_array(this._headers)
  end

  def security_details(this) do
    this._initializer[:securityDetails] || nil
  end

  def server_addr(this) do
    this._initializer[:serverAddr] || nil
  end

  def timing(this) do
    %{
      startTime: -1,
      domainLookupStart: -1,
      domainLookupEnd: -1,
      connectStart: -1,
      secureConnectionStart: -1,
      connectEnd: -1,
      requestStart: -1,
      responseStart: -1
    }
    |> Map.merge(this._initializer[:timing] || %{})
    |> Map.put(:responseEnd, this._initializer[:responseEndTiming] || -1)
  end

  def body(this) do
    ChannelOwner._wrap_api_call(
      this._request,
      fn _ ->
        try do
          result =
            channel_call(
              this._request,
              :fetchResponseBody,
              %{fetchUid: _fetch_uid(this)},
              TimeoutSettings.k_no_timeout()
            )

          if result[:binary] == nil, do: raise("Response has been disposed")
          result.binary
        rescue
          e ->
            if Errors.is_target_closed_error(e),
              do: reraise(RuntimeError.exception("Response has been disposed"), __STACKTRACE__)

            reraise e, __STACKTRACE__
        end
      end,
      %{internal: true}
    )
  end

  def text(this) do
    content = body(this)
    content
  end

  def json(this) do
    content = text(this)
    ClientHelper.json_parse(content)
  end

  # [Symbol.asyncDispose]  -- not ported: await using

  def dispose(this) do
    channel_call(this._request, :disposeAPIResponse, %{fetchUid: _fetch_uid(this)}, TimeoutSettings.k_no_timeout())
    nil
  end

  def _inspect(this) do
    headers = Enum.map(headers_array(this), fn %{name: name, value: value} -> "  #{name}: #{value}" end)
    "APIResponse: #{status(this)} #{status_text(this)}\n#{Enum.join(headers, "\n")}"
  end

  def _fetch_uid(this) do
    this._initializer.fetchUid
  end

  def _fetch_log(this) do
    %{log: log} = channel_call(this._request, :fetchLog, %{fetchUid: _fetch_uid(this)}, TimeoutSettings.k_no_timeout())
    log
  end
end
