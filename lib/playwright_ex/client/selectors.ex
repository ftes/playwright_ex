defmodule PlaywrightEx.Client.Selectors do
  @upstream "packages/playwright-core/src/client/selectors.ts"
  @moduledoc "Port of `#{@upstream}`: a runtime object (its engines and contexts live in the loop's heap)."
  import PlaywrightEx.Client.ChannelOwner, only: [channel_call: 4]
  import PlaywrightEx.Runtime.Heap

  alias PlaywrightEx.Client.ClientHelper
  alias PlaywrightEx.Client.Locator
  alias PlaywrightEx.Client.TimeoutSettings
  alias PlaywrightEx.Runtime.EventLoop
  alias PlaywrightEx.Runtime.Promise

  # Elixir only: the handle is the facade's struct, `%PlaywrightEx.Selectors{}` (gen.api copies these fields).
  @doc false
  def __struct_fields__, do: [:guid, :loop, :heap]

  def new do
    this = new_object(PlaywrightEx.Selectors)
    put(this, :_selectorEngines, [])
    put(this, :_testIdAttributeName, nil)
    put(this, :_contextsForSelectors, [])
    this
  end

  # `script` is JS source (a string), or `%{path: ...}` / `%{content: ...}` (PLAN: no function serialization).
  def register(this, name, script, options \\ %{}) do
    if Enum.any?(get(this, :_selectorEngines), &(&1.name == name)),
      do: raise(~s(selectors.register: "#{name}" selector engine has been already registered))

    source = ClientHelper.evaluation_script(script, nil, false)
    selector_engine = Map.merge(options || %{}, %{name: name, source: source})

    for context <- get(this, :_contextsForSelectors),
        do:
          channel_call(
            context,
            :registerSelectorEngine,
            %{selectorEngine: selector_engine},
            TimeoutSettings.k_no_timeout()
          )

    update(this, :_selectorEngines, &(&1 ++ [selector_engine]))
    nil
  end

  def set_test_id_attribute(this, attribute_name) do
    put(this, :_testIdAttributeName, attribute_name)
    Locator.set_test_id_attribute(attribute_name)

    # Under the baton: a sync member, called without it.
    EventLoop.with_baton(this.loop, fn ->
      for context <- get(this, :_contextsForSelectors) do
        put(context, :_options, Map.put(get(context, :_options), :testIdAttributeName, attribute_name))

        Promise.async(fn ->
          channel_call(
            context,
            :setTestIdAttributeName,
            %{testIdAttributeName: attribute_name},
            TimeoutSettings.k_no_timeout()
          )
        end)
        |> Promise.catch_(fn _ -> nil end)
      end
    end)

    nil
  end

  def _with_selector_options(this, options) do
    Map.merge(options || %{}, %{
      selectorEngines: get(this, :_selectorEngines),
      testIdAttributeName: get(this, :_testIdAttributeName)
    })
  end
end
