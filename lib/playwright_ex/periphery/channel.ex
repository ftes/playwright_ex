defmodule PlaywrightEx.Channel do
  @moduledoc false

  def timeout_opt, do: [type: :timeout, required: true, doc: "Maximum time for the operation (milliseconds)."]

  # set to true to find unknown flags during local development
  @fail_on_unknown_opts false

  if @fail_on_unknown_opts do
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
