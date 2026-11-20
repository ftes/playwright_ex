defmodule Playwright.Root do
  @moduledoc false
  # The hand-written part of the root module `Playwright`, whose facade (upstream's `Playwright`
  # class, as `require('playwright')` is the Playwright object) `mix playwright.gen.api`
  # generates with `use Playwright.Root`. Its moduledoc's introduction is in
  # `Mix.Playwright.ApiRules`.

  @devices_key {__MODULE__, :devices, :keyword}

  # A descriptor's JS keys as the option keys of `Playwright.Browser.new_context/2`, as the
  # generated `Playwright.devices/1` converts the driver's, and as a keyword list, the Elixir
  # options' shape (`config :playwright, :test, Playwright.device("Desktop Chrome")`). Its nested
  # values (`viewport`) stay maps.
  @doc false
  # Converted once per VM. The key names the shape, so a VM that cached another one (maps, before
  # a recompile) doesn't serve it.
  def devices do
    case :persistent_term.get(@devices_key, nil) do
      nil ->
        {:object, schema} = Playwright.Browser.__options_type__(:new_context)
        keys = Map.new(schema, fn {key, {js_key, _type}} -> {js_key, key} end)

        devices =
          Map.new(Playwright.Isomorphic.DeviceDescriptors.device_descriptors(), fn {name, descriptor} ->
            {name, Enum.map(descriptor, fn {key, value} -> {Map.get(keys, key, key), value} end)}
          end)

        :persistent_term.put(@devices_key, devices)
        devices

      devices ->
        devices
    end
  end

  @doc false
  def device(name) do
    devices = devices()

    case devices do
      %{^name => device} ->
        device

      _unknown ->
        closest =
          if is_binary(name),
            do: devices |> Map.keys() |> Enum.sort_by(&String.jaro_distance(&1, name), :desc) |> Enum.take(3),
            else: []

        raise ArgumentError,
              "Playwright.device/1: unknown device, expected a name of Playwright.devices/0, got: #{inspect(name)}" <>
                if(closest == [], do: "", else: ". Did you mean #{Enum.map_join(closest, ", ", &inspect/1)}?")
    end
  end

  # The device names for the docs of `devices/0`: without the `landscape` variants, and those
  # that have none.
  defp device_names do
    names = Playwright.Isomorphic.DeviceDescriptors.device_descriptors() |> Map.keys() |> Enum.sort()
    {landscape, names} = Enum.split_with(names, &String.ends_with?(&1, " landscape"))
    {names, Enum.reject(names, &((&1 <> " landscape") in landscape))}
  end

  defmacro __using__(_opts) do
    {names, no_landscape} = device_names()
    code = fn names -> Enum.map_join(names, ", ", &"`#{inspect(&1)}`") end

    quote do
      @typedoc """
      An error a call fails with: the tuple forms return `{:error, error}`, the bang forms raise it.
      These are what a JS call rejects with: Playwright's errors (`Playwright.PlaywrightError` for
      JS `Error`, `Playwright.TimeoutError`, `Playwright.TargetClosedError`,
      `Playwright.AbortError`, the matchers' `Playwright.ExpectError`), and what the client
      throws itself: `RuntimeError` for a JS `new Error(message)` ("Route is already handled!"), the
      protocol's `ValidationError` for an argument of the wrong type, `JSON.DecodeError` where JS's
      `JSON.parse` fails and `File.Error` for local files. Anything else (`ArgumentError` for an
      unknown option, a `FunctionClauseError`) is a bug or a misuse and raises in both forms.
      """
      @type error ::
              Playwright.PlaywrightError.t()
              | Playwright.TimeoutError.t()
              | Playwright.TargetClosedError.t()
              | Playwright.AbortError.t()
              | Playwright.ExpectError.t()
              | %RuntimeError{}
              | %Playwright.Protocol.ValidatorPrimitives.ValidationError{}
              | %JSON.DecodeError{}
              | %File.Error{}

      @doc """
      Playwright's device descriptors by name, as static data: upstream's
      `import { devices } from '@playwright/test'`. A descriptor is a keyword list of the options
      of `Playwright.Browser.new_context/2` for that device (`user_agent`, `viewport`,
      `device_scale_factor`, `is_mobile`, `has_touch`, and its `default_browser_type`, which
      `new_context` ignores), the options `devices/1` returns from a driver as a map:

          iphone = Playwright.devices()["iPhone 13"]
          context = Browser.new_context!(browser, iphone)

      Upstream's `{ ...devices['iPhone 13'], viewport: { width: 800, height: 600 } }` is
      `iphone ++ [viewport: %{width: 800, height: 600}]`: a later key wins, as in JS's spread.

      It needs no driver, so it works at compile time. A name that isn't a device's gives
      `nil`, which `context_options:` rejects: `device/1` raises instead, naming the closest.
      The data is that of the pinned Playwright version.

      ## Devices

      #{unquote(code.(names))}.

      Each also has a landscape variant (`"iPhone 13 landscape"`), but
      #{unquote(code.(no_landscape))}.
      """
      @spec devices() :: %{optional(String.t()) => Playwright.Browser.new_context_options()}
      def devices, do: Playwright.Root.devices()

      @doc """
      The device descriptor of `name` in `devices/0`, upstream's `devices['iPhone 13']`: a keyword
      list of options. An unknown name raises `ArgumentError`, naming the closest ones.

          use Playwright.Test, Playwright.device("iPhone 13")

          # config/runtime.exs
          if config_env() == :test, do: config(:playwright, :test, Playwright.device("iPhone 13"))
      """
      @spec device(String.t()) :: Playwright.Browser.new_context_options()
      def device(name), do: Playwright.Root.device(name)

      @doc """
      The root `Playwright` object of the driver started as `name`.

      While a lost driver is being replaced (see `Playwright.Supervisor`), this waits for the new
      driver and returns its root, also when called from a `disconnected` listener. It exits if the
      supervisor is not running, or not restarting the driver.
      """
      @spec instance(atom()) :: t()
      def instance(name \\ __MODULE__) do
        # An await: in a listener, the connection goes on (a lost driver's close emulation finishes).
        Playwright.Runtime.Invocation.yield()
        Playwright.Supervisor.playwright(name)
      end
    end
  end
end
