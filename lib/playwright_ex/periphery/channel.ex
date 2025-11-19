defmodule PlaywrightEx.Channel do
  @moduledoc false
  def timeout_opt, do: [type: :timeout, required: true, doc: "Maximum time for the operation (milliseconds)."]

  def validate_known!(opts, schema) do
    {known, unknown} = Keyword.split(opts, Keyword.keys(schema.schema))
    NimbleOptions.validate!(known, schema) ++ unknown
  end
end
