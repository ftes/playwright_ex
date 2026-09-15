defmodule PlaywrightEx.Request do
  @moduledoc """
  Interact with a Playwright network request.
  """

  alias PlaywrightEx.ChannelResponse
  alias PlaywrightEx.Connection

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      timeout: PlaywrightEx.Channel.timeout_opt()
    )

  @doc """
  Waits for the request's response headers and returns `{:ok, %{guid: response_id}}`.

  Returns `{:ok, nil}` if the request fails without receiving a response.
  HTTP error statuses such as 404 still produce a response. Redirects have
  separate requests; this returns the response for the supplied request.

  Response events do not need to be enabled. Read response metadata with
  `PlaywrightEx.Connection.initializer!(connection, response_id)`.

  Reference: https://playwright.dev/docs/api/class-request#request-response

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type response_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec response(PlaywrightEx.guid(), [response_opt() | PlaywrightEx.unknown_opt()]) ::
          {:ok, %{guid: PlaywrightEx.guid()} | nil} | {:error, any()}
  def response(request_id, opts \\ []) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)

    connection
    |> Connection.send(%{guid: request_id, method: :response, params: Map.new(opts)}, timeout)
    |> ChannelResponse.unwrap(&Map.get(&1, :response))
  end
end
