defmodule PlaywrightEx.FilePayload do
  @moduledoc """
  An in-memory file passed to a Playwright file input.

  `buffer` contains the raw file bytes. It is base64-encoded only when the
  payload is serialized for the Playwright protocol.

  Reference: https://playwright.dev/docs/api/class-locator#locator-set-input-files
  """

  @enforce_keys [:name, :buffer]
  defstruct [:name, :buffer, :mime_type]

  @type t :: %__MODULE__{
          name: String.t(),
          buffer: binary(),
          mime_type: String.t() | nil
        }
end
