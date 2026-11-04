defmodule Playwright.Impl.Protocol do
  # upstream: Protocol.java (package-private DTO classes; one nested module per class)

  defmodule SerializedError do
    # upstream: Protocol.java:66
    defmodule Error do
      # upstream: Protocol.java:72
      defstruct [:message, :name, :stack]

      defimpl String.Chars do
        # upstream: Protocol.java:72
        def to_string(e) do
          "Error {\n" <>
            "  message='#{e.message}\n" <> "  name='#{e.name}\n" <> "  stack='#{e.stack}\n" <> "}"
        end
      end
    end

    defstruct [:error, :value]

    def from_json(json) do
      error =
        json["error"] &&
          struct(Error, message: json["error"]["message"], name: json["error"]["name"], stack: json["error"]["stack"])

      %__MODULE__{error: error, value: json["value"]}
    end

    defimpl String.Chars do
      # upstream: Protocol.java:84
      def to_string(e) do
        if e.error != nil, do: Kernel.to_string(e.error), else: "SerializedError{value=#{inspect(e.value)}}"
      end
    end
  end

  defmodule ExpectedTextValue do
    # upstream: Protocol.java:94
    defstruct [:string, :regex_source, :regex_flags, :ignore_case, :match_substring, :normalize_white_space]
  end

  defmodule FrameExpectOptions do
    # upstream: Protocol.java:103
    defstruct [
      :expression_arg,
      :expected_text,
      :selector,
      :expected_number,
      :expected_value,
      :use_inner_text,
      is_not: false,
      timeout: nil
    ]
  end

  defmodule FrameExpectResult do
    # upstream: Protocol.java:114
    defmodule Received do
      # upstream: Protocol.java:115
      defstruct [:value, :aria_snapshot]
    end

    defstruct [:received, :error_message, :log, matches: false]
  end

  defmodule FrameExpectErrorDetails do
    # upstream: Protocol.java:125
    defstruct [:received, :timed_out, :custom_error_message]
  end

  defmodule SerializedArgument do
    # upstream: Protocol.java (SerializedArgument)
    defstruct [:value, handles: []]
  end
end
