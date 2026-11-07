defmodule PlaywrightEx.Client.Decorators do
  @moduledoc false
  # Elixir only: the TS method decorators of channelOwner.ts as module attributes before a `def` or
  # `defp` (its first clause), injected by `use PlaywrightEx.Client.ChannelOwner`:
  #
  #     @api_call %{title: "Create page"}   # @apiCall({ title: 'Create page' }); `%{}` for @apiCall()
  #     @internal true                      # @internal
  #
  # The function is replaced (`defoverridable`) by one that runs the original (`super`, the
  # decorated `method`) through `ChannelOwner.wrap_api_call_decorator/1`, as the JS decorator
  # replaces the method: the whole body runs in the api zone, so do JS default parameters, which
  # are applied in the body (PORTING: `nil` defaults, `x = if x == nil, do: default, else: x`).
  # Only the full arity is wrapped: a `\\` default is evaluated outside the zone, so keep those
  # literals. The first argument is the receiver (`this`).

  defmacro __using__(_opts) do
    quote do
      Module.register_attribute(__MODULE__, :api_call, [])
      Module.register_attribute(__MODULE__, :internal, [])
      Module.register_attribute(__MODULE__, :__decorated__, accumulate: true)
      @on_definition PlaywrightEx.Client.Decorators
      @before_compile PlaywrightEx.Client.Decorators
    end
  end

  @doc false
  def __on_definition__(env, kind, name, args, _guards, _body) do
    options =
      cond do
        Module.get_attribute(env.module, :internal) -> %{internal: true}
        options = Module.get_attribute(env.module, :api_call) -> options
        true -> nil
      end

    if options do
      Module.delete_attribute(env.module, :api_call)
      Module.delete_attribute(env.module, :internal)
      Module.put_attribute(env.module, :__decorated__, {kind, name, length(args), options})
    end
  end

  defmacro __before_compile__(env) do
    for {kind, name, arity, options} <- Enum.reverse(Module.get_attribute(env.module, :__decorated__)) do
      args = Macro.generate_arguments(arity, env.module)

      body =
        quote do
          PlaywrightEx.Client.ChannelOwner.wrap_api_call_decorator(unquote(Macro.escape(options))).(
            unquote(hd(args)),
            fn -> super(unquote_splicing(args)) end
          )
        end

      quote do
        defoverridable [{unquote(name), unquote(arity)}]
        unquote({kind, [], [{name, [], args}, [do: body]]})
      end
    end
  end
end
