defmodule Playwright.Runtime.Facade do
  @moduledoc """
  Runtime support (not ported from upstream) for the facade that `mix playwright.gen.api`
  generates from `api.json` (`Playwright.Browser`, ...).

  The facade converts Elixir arguments to the shapes the ported client expects, then runs the
  call in `Playwright.Runtime.Api.call/3`:

    * Options: a keyword list or map with snake_case keys (`executable_path:`) becomes a map
      with the JS names (`executablePath`). Unknown keys raise `ArgumentError`, as there are
      no options beyond the official ones.
    * Nested objects (option values, positional arguments, in lists too) are JS values, as in
      the Python client: maps with the JS keys (`%{sameSite: "Lax"}`), passed as they are, so
      values returned by the client round-trip. Only their keys are checked: an unknown one
      raises `ArgumentError` naming where it is (`cookies[0].http_only`). Cookies and storage
      states have the protocol's keys, also those the docs leave out, which results carry.
      Only these, passed on to the protocol as they are, take string keys too (a storage state
      from `JSON.decode!/1`); other nested objects take atoms, as the client reads them.
    * Enums of options and positional arguments: atoms (`:no_preference`) become the wire
      strings (`"no-preference"`); strings pass through.
    * `timeout: :infinity` is `timeout: 0` (no timeout, as in JS), likewise a positional
      `timeout` (`set_default_timeout(context, :infinity)`).

  A type is `nil` (passed through), `:timeout` (a positional timeout), `{:object, %{key => {js_key, type}}}`
  (options), `{:fields, %{js_key => type}}` (a nested object), `{:protocol, %{js_key => type}}` (one
  the client passes on as it is: string keys too, as the protocol validator reads them),
  `{:array, type}`, `{:values, type}` (a dictionary's values), `{:enum, %{atom => string}}` or
  `{:union, [type]}`.
  """
  alias Playwright.Runtime.Api
  alias Playwright.Runtime.Promise

  # The errors a call fails with (`t:Playwright.error/0`), as upstream rejects with them.
  @errors [
    Playwright.PlaywrightError,
    Playwright.TimeoutError,
    Playwright.TargetClosedError,
    Playwright.AbortError,
    Playwright.ExpectError,
    # JS `new Error(message)` and the protocol's `ValidationError`, thrown by the client.
    RuntimeError,
    Playwright.Protocol.ValidatorPrimitives.ValidationError,
    # `JSON.parse` and `fs` errors.
    JSON.DecodeError,
    File.Error
  ]

  @doc """
  Whether `e` is an error a call fails with (`t:Playwright.error/0`). Anything else is a bug
  or a misuse and raises from the tuple forms too.
  """
  def error?(%module{}) when module in @errors, do: true
  def error?(_e), do: false

  @doc """
  Runs an async call: `{:ok, value}`, or `{:error, exception}` for an error it fails with
  (`error?/1`); anything else is raised.
  """
  def async(api_name, receiver, fun) do
    {:ok, Api.call(api_name, receiver, fun)}
  rescue
    e -> if error?(e), do: {:error, e}, else: reraise(e, __STACKTRACE__)
  end

  @doc "Runs an async call and returns its value, raising on error."
  def async!(api_name, receiver, fun), do: Api.call(api_name, receiver, fun)

  @doc "Runs an async call that returns `void` in JS: `:ok`, or `{:error, exception}`."
  def async_void(api_name, receiver, fun) do
    with {:ok, _} <- async(api_name, receiver, fun), do: :ok
  end

  @doc "Runs an async call that returns `void` in JS: `:ok`, raising on error."
  def async_void!(api_name, receiver, fun) do
    async!(api_name, receiver, fun)
    :ok
  end

  @doc """
  Starts an async call without awaiting it, as JS does with `const p = page.waitForEvent(...)`:
  the call runs until its first `await` (the wait is set up), then a promise handle is returned,
  awaited with `Playwright.Promise.await/1`.
  """
  # A latch owned by the calling process (freed when it exits). A user listener's process exits
  # with its subscription (a `once` right after the event), while the promise it started lives
  # on (JS: `.then(ws => ws.waitForEvent(...))`): there, a latch on the receiver.
  def promise(api_name, receiver, fun) do
    owner =
      if Process.get(:pw_listener) && is_map(receiver) && Map.get(receiver, :table),
        do: [owner: receiver],
        else: [shared: true]

    Api.call(api_name, receiver, fn -> Promise.async(fun, owner) end)
  end

  @doc """
  Runs `fun` (an `on`, `once`, `off`, ... of the facade) with its listener marked as a user
  listener: it runs in a subscription process of its own (see `Playwright.Client.EventEmitter`).
  """
  def listen(fun) do
    previous = Process.put(:pw_user_listener, true)

    try do
      fun.()
    after
      if previous, do: Process.put(:pw_user_listener, previous), else: Process.delete(:pw_user_listener)
    end
  end

  @doc """
  Awaits a promise of `promise/3` that never leaves the caller (`wait_for_request!`): its value,
  raising if it is rejected.
  """
  def await!(promise), do: Playwright.Promise.await!(promise)

  @doc """
  The callback form of a wait (`expect_popup`): starts the wait (`promise/3`), runs `action`, then
  awaits the wait: `{:ok, value}` or `{:error, exception}`. Exceptions raised by `action` propagate.
  """
  def expect(api_name, receiver, fun, action) do
    # The handle never leaves this function: a local promise.
    promise = Api.call(api_name, receiver, fn -> Promise.async(fun) end)
    run_action(action, promise)
    Playwright.Promise.await(promise)
  end

  @doc "Like `expect/4`, but returns the value and raises on error."
  def expect!(api_name, receiver, fun, action) do
    # The handle never leaves this function: a local promise.
    promise = Api.call(api_name, receiver, fn -> Promise.async(fun) end)
    run_action(action, promise)
    Playwright.Promise.await!(promise)
  end

  # Elixir only: when the action raises, the wait's late result is dropped (unalias), else it
  # would reach the caller's mailbox once the wait settles (Python leaves the future unawaited).
  defp run_action(action, promise) do
    action.()
  catch
    kind, reason ->
      Promise.free(promise)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  @doc """
  Runs a matcher (`Playwright.Expect`): `:ok`, or `{:error, exception}` as `async/3` returns it
  (`Playwright.ExpectError` when the expectation is not met). The API name
  comes from the matcher's title (`Expect "toHaveText"`), as upstream's does.
  """
  def matcher(receiver, fun), do: async_void(nil, receiver, fun)

  @doc """
  A matcher's receiver and info (`isNot`, `isSoft`, `message`): a negated receiver
  (`Playwright.Expect.not_/1`, JS `expect(x).not`) negates the matcher, a soft one
  (`Playwright.Expect.soft/1`, `expect.soft(x)`) makes it soft, one with a message
  (`Playwright.Expect.message/2`, `expect(x, message)`) gives it that message. JS has no
  `expect(x).not.not`, so a `not_to_*` matcher (`is_not`) raises `ArgumentError` for a negated
  receiver.
  """
  def matcher_info(%{__struct__: Playwright.Expect, isNot: true}, true, api_name),
    do: raise(ArgumentError, "#{api_name}: the receiver is negated already (JS has no expect(x).not.not)")

  def matcher_info(%{__struct__: Playwright.Expect, actual: actual, isNot: n, isSoft: s, message: m}, is_not, _),
    do: {actual, %{isNot: n or is_not, isSoft: s, message: m}}

  def matcher_info(actual, is_not, _api_name), do: {actual, %{isNot: is_not, isSoft: false}}

  @doc "Like `matcher/2`, but raises (`Playwright.ExpectError` when the expectation is not met)."
  def matcher!(receiver, fun), do: async_void!(nil, receiver, fun)

  @doc """
  Like `matcher/2`, for a matcher with a value (`Playwright.Expect.to_pass/2`, the passing
  attempt's): `{:ok, value}`, or `{:error, exception}`. A negated one (`info` of
  `matcher_info/3`) has none: `matcher/2`.
  """
  def matcher_value(receiver, %{isNot: true}, fun), do: matcher(receiver, fun)
  def matcher_value(receiver, _info, fun), do: async(nil, receiver, fun)

  @doc "Like `matcher_value/3`, but returns the value and raises on error."
  def matcher_value!(receiver, %{isNot: true}, fun), do: matcher!(receiver, fun)
  def matcher_value!(receiver, _info, fun), do: async!(nil, receiver, fun)

  @doc """
  Converts `options` (keyword list or map) of type `{:object, schema}` for the call `api_name`.
  A matcher passes its `function` (`__ENV__.function`), named in the hint of an unknown `:message`.
  """
  def options!(options, type, api_name, function \\ nil)

  def options!(options, {:object, schema}, api_name, function) when is_list(options) or is_map(options),
    do: object!(options, schema, api_name, [], function)

  # Not an options object (`page.evaluate(fn, 1, 2)`): passed on, the client checks it
  # (`assertEvaluateOptions`).
  def options!(options, {:object, _schema}, _api_name, _function), do: options

  @doc """
  Like `options!/3`, but the options may also be a result of the call (a map with the JS keys,
  `credentials.create(known.rpId, known)`): its JS keys become the option keys, the `ignored`
  JS keys (result fields that are no options) are dropped. Other keys still raise.
  """
  def result_options!(options, {:object, schema} = type, ignored, api_name) when is_map(options) do
    option_keys = Map.new(schema, fn {key, {js_key, _type}} -> {js_key, key} end)

    options
    |> Map.drop(ignored)
    |> Map.new(fn {key, value} -> {Map.get(option_keys, key, key), value} end)
    |> options!(type, api_name)
  end

  def result_options!(options, type, _ignored, api_name), do: options!(options, type, api_name)

  @doc """
  A dictionary of option objects with JS keys (device descriptors) keyed as options:
  `keys` maps a JS key to its option key (`userAgent: :user_agent`), others stay.
  """
  def options_dictionary(dictionary, keys) do
    Map.new(dictionary, fn {name, object} ->
      {name, Map.new(object, fn {key, value} -> {Map.get(keys, key, key), value} end)}
    end)
  end

  @doc "Converts the positional argument `name` (its Elixir name, for errors) of `type`."
  def arg!(value, type, api_name, name), do: convert!(value, type, api_name, [{:argument, name}])

  @doc """
  The JS event name for `event` (atom, or the JS name as a string) in `events`; `nil` (an optional
  event left out) stays `nil`. With `open?`, any string is an event too (CDP events of a `CDPSession`).
  """
  def event!(event, events, api_name, open? \\ false) do
    cond do
      # An optional event left out (`remove_all_listeners(page)`: every event).
      event == nil -> nil
      is_atom(event) and Map.has_key?(events, event) -> Map.fetch!(events, event)
      is_binary(event) and (open? or event in Map.values(events)) -> event
      true -> raise ArgumentError, "#{api_name}: unknown event #{inspect(event)}, expected one of #{keys(events)}"
    end
  end

  defp convert!(nil, _type, _api_name, _path), do: nil
  defp convert!(value, nil, _api_name, _path), do: value
  defp convert!(value, :timeout, _api_name, _path), do: timeout(:timeout, value)

  defp convert!(value, {:fields, fields}, api_name, path) do
    if object?(value), do: fields!(value, fields, api_name, path, false)
    value
  end

  # Passed on to the protocol as it is, whose validator reads string keys too (a storage state
  # from `JSON.decode!/1`).
  defp convert!(value, {:protocol, fields}, api_name, path) do
    if object?(value), do: fields!(value, fields, api_name, path, true)
    value
  end

  defp convert!(value, {:array, type}, api_name, path) when is_list(value),
    do:
      value
      |> Enum.with_index()
      |> Enum.map(fn {item, index} -> convert!(item, type, api_name, [{:index, index} | path]) end)

  # A dictionary: a map, or a keyword list (`FormData`).
  defp convert!(value, {:values, type}, api_name, path)
       when is_list(value) or (is_map(value) and not is_struct(value)) do
    for {key, item} <- value, do: convert!(item, type, api_name, [key | path])
    value
  end

  defp convert!(value, {:enum, literals}, api_name, path) when is_atom(value) and value not in [:null, true, false] do
    case literals do
      %{^value => literal} ->
        literal

      _ ->
        raise ArgumentError,
              "#{api_name}: invalid value #{inspect(value)} for #{name(path)}, expected one of #{keys(literals)}"
    end
  end

  defp convert!(value, {:union, types}, api_name, path) do
    type =
      cond do
        object?(value) -> Enum.find(types, &match?({tag, _} when tag in [:fields, :protocol], &1))
        is_list(value) -> Enum.find(types, &match?({:array, _}, &1))
        is_atom(value) -> Enum.find(types, &match?({:enum, _}, &1))
        true -> nil
      end

    convert!(value, type, api_name, path)
  end

  defp convert!(value, _type, _api_name, _path), do: value

  defp object!(value, schema, api_name, path, function) do
    Map.new(value, fn {key, value} ->
      case Map.get(schema, key) do
        {js_key, type} ->
          {js_key, timeout(js_key, convert!(value, type, api_name, [key | path]))}

        nil ->
          raise ArgumentError,
                "#{api_name}: unknown option #{name([key | path])}, expected one of #{keys(schema)}" <>
                  hint(function, [key | path])
      end
    end)
  end

  # A matcher's message is its receiver's (JS `expect(actual, message)`), not an option: the
  # matcher as called, its arguments elided.
  defp hint({name, _arity}, [:message]),
    do:
      ". A matcher's custom message goes with Playwright.Expect.message/2 (JS expect(actual, message)), " <>
        ~s[for Expect.#{name}: x |> Expect.message("...") |> Expect.#{name}(...)]

  defp hint(_function, _path), do: ""

  defp fields!(value, fields, api_name, path, string_keys?) do
    for {key, value} <- value do
      case field(fields, key, string_keys?) do
        {:ok, type} ->
          convert!(value, type, api_name, [key | path])

        :error ->
          raise ArgumentError, "#{api_name}: unknown field #{name([key | path])}, expected one of #{keys(fields)}"
      end
    end
  end

  defp field(fields, key, true) when is_binary(key),
    do: Enum.find_value(fields, :error, fn {field, type} -> if Atom.to_string(field) == key, do: {:ok, type} end)

  defp field(fields, key, _string_keys?), do: Map.fetch(fields, key)

  defp timeout(:timeout, :infinity), do: 0
  defp timeout(_key, value), do: value

  defp object?(value), do: is_map(value) and not is_struct(value)

  # [:server, :proxy] is ":proxy.server" (an option), [:httpOnly, {:index, 0}, {:argument, "cookies"}]
  # is "cookies[0].httpOnly" (a positional argument, by its name).
  defp name(path) do
    path
    |> Enum.reverse()
    |> Enum.reduce("", fn
      {:argument, name}, "" -> name
      {:index, index}, name -> "#{name}[#{index}]"
      option, "" -> inspect(option)
      key, name when is_atom(key) -> "#{name}.#{key}"
      key, name -> "#{name}.#{inspect(key)}"
    end)
  end

  defp keys(map), do: map |> Map.keys() |> Enum.sort() |> Enum.map_join(", ", &inspect/1)
end
