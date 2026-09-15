defmodule PlaywrightEx.Channel do
  @moduledoc false

  def timeout_opt,
    do: [
      type: :timeout,
      required: true,
      doc: "Operation timeout in milliseconds. `0` means no waiting; `:infinity` disables the timeout."
    ]

  def connection_opt,
    do: [
      type: :any,
      type_spec: quote(do: GenServer.name()),
      default: PlaywrightEx.Supervisor.Connection,
      doc: "The Connection process name. Defaults to `PlaywrightEx.Supervisor.Connection`."
    ]

  if Application.compile_env(:playwright_ex, :fail_on_unknown_opts) do
    def validate_known!(opts, schema) do
      NimbleOptions.validate!(opts, schema)
    end
  else
    def validate_known!(opts, schema) do
      {known, unknown} = Keyword.split(opts, Keyword.keys(schema.schema))
      NimbleOptions.validate!(known, schema) ++ unknown
    end
  end
end
