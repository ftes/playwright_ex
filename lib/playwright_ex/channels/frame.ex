defmodule PlaywrightEx.Frame do
  @moduledoc """
  Interact with a Playwright `Frame` (usually the "main" frame of a browser page).

  There is no official documentation, since this is considered Playwright internal.

  References:
  - https://github.com/microsoft/playwright/blob/main/packages/playwright-core/src/client/frame.ts
  """

  import PlaywrightEx.Connection, only: [post: 2]
  import PlaywrightEx.Result, only: [from_response: 2, map: 2]

  alias PlaywrightEx.Serialization

  def goto(frame_id, url, opts \\ []) do
    params = %{url: url}

    %{guid: frame_id, method: :goto, params: params}
    |> post(opts[:timeout])
    |> from_response(& &1)
  end

  def url(frame_id, opts \\ []) do
    %{guid: frame_id, method: :url, params: %{}}
    |> post(opts[:timeout])
    |> from_response(& &1.result.value)
  end

  def evaluate(frame_id, js, opts \\ []) do
    params =
      opts
      |> Enum.into(%{expression: js, is_function: false, arg: nil})
      |> Map.update!(:arg, &Serialization.serialize_arg/1)

    %{guid: frame_id, method: :evaluate_expression, params: params}
    |> post(opts[:timeout])
    |> from_response(& &1.result.value)
    |> map(&Serialization.deserialize_arg/1)
  end

  def press(frame_id, selector, key, opts \\ []) do
    opts = Keyword.validate!(opts, [:timeout, delay: 0])

    params =
      opts
      |> Enum.into(%{selector: selector, key: key})
      |> Map.update!(:timeout, &(&1 + opts[:delay]))

    %{guid: frame_id, method: :press, params: params}
    |> post(opts[:timeout])
    |> from_response(& &1)
  end

  def type(frame_id, selector, text, opts \\ []) do
    opts = Keyword.validate!(opts, [:timeout, delay: 0])

    params =
      opts
      |> Enum.into(%{selector: selector, text: text})
      |> Map.update!(:timeout, &(&1 + opts[:delay] * String.length(text)))

    %{guid: frame_id, method: :type, params: params}
    |> post(opts[:timeout])
    |> from_response(& &1)
  end

  def title(frame_id, opts \\ []) do
    %{guid: frame_id, method: :title}
    |> post(opts[:timeout])
    |> from_response(& &1.result.value)
  end

  def expect(frame_id, opts \\ []) do
    params = Enum.into(opts, %{is_not: false})

    %{guid: frame_id, method: :expect, params: params}
    |> post(opts[:timeout])
    |> from_response(& &1.result.matches)
  end

  def wait_for_selector(frame_id, opts \\ []) do
    %{guid: frame_id, method: :wait_for_selector, params: Map.new(opts)}
    |> post(opts[:timeout])
    |> from_response(& &1.result.element)
  end

  def inner_html(frame_id, selector, opts \\ []) do
    params = Enum.into(opts, %{selector: selector})

    %{guid: frame_id, method: "innerHTML", params: params}
    |> post(opts[:timeout])
    |> from_response(& &1.result.value)
  end

  def content(frame_id, opts \\ []) do
    %{guid: frame_id, method: :content}
    |> post(opts[:timeout])
    |> from_response(& &1.result.value)
  end

  def fill(frame_id, selector, value, opts \\ []) do
    params = %{selector: selector, value: value, strict: true}
    params = Enum.into(opts, params)

    %{guid: frame_id, method: :fill, params: params}
    |> post(opts[:timeout])
    |> from_response(& &1)
  end

  def select_option(frame_id, selector, options, opts \\ []) do
    params = %{selector: selector, options: options, strict: true}
    params = Enum.into(opts, params)

    %{guid: frame_id, method: :select_option, params: params}
    |> post(opts[:timeout])
    |> from_response(& &1)
  end

  def check(frame_id, selector, opts \\ []) do
    params = %{selector: selector, strict: true}
    params = Enum.into(opts, params)

    %{guid: frame_id, method: :check, params: params}
    |> post(opts[:timeout])
    |> from_response(& &1)
  end

  def uncheck(frame_id, selector, opts \\ []) do
    params = %{selector: selector, strict: true}
    params = Enum.into(opts, params)

    %{guid: frame_id, method: :uncheck, params: params}
    |> post(opts[:timeout])
    |> from_response(& &1)
  end

  def set_input_files(frame_id, selector, paths, opts \\ []) do
    params = %{selector: selector, local_paths: paths, strict: true}
    params = Enum.into(opts, params)

    %{guid: frame_id, method: :set_input_files, params: params}
    |> post(opts[:timeout])
    |> from_response(& &1)
  end

  def click(frame_id, selector, opts \\ []) do
    params = %{selector: selector, strict: true}
    params = Enum.into(opts, params)

    %{guid: frame_id, method: :click, params: params}
    |> post(opts[:timeout])
    |> from_response(& &1)
  end

  def blur(frame_id, selector, opts \\ []) do
    params = %{selector: selector}
    params = Enum.into(opts, params)

    %{guid: frame_id, method: :blur, params: params}
    |> post(opts[:timeout])
    |> from_response(& &1)
  end

  def drag_and_drop(frame_id, source_selector, target_selector, opts \\ []) do
    params = %{source: source_selector, target: target_selector, strict: true}
    params = Enum.into(opts, params)

    %{guid: frame_id, method: :drag_and_drop, params: params}
    |> post(opts[:timeout])
    |> from_response(& &1)
  end
end
