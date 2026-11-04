defmodule Playwright.Impl.PageAssertionsImpl do
  # upstream: PageAssertionsImpl.java:27
  use Playwright.Impl.AssertionsBase
  alias Playwright.Impl.{BrowserContextImpl, FrameImpl, PageImpl, Utils}
  alias Playwright.Impl.Protocol.{ExpectedTextValue, FrameExpectOptions}

  defstruct [:actual_page, is_not: false]
  @type t :: %__MODULE__{}

  # upstream: PageAssertionsImpl.java:30
  def new(page), do: new(page, false)

  # upstream: PageAssertionsImpl.java:34
  defp new(page, is_not), do: %__MODULE__{actual_page: page, is_not: is_not}

  # upstream: PageAssertionsImpl.java:40
  @impl true
  def do_expect(this, expression, expect_options, title) do
    frame = PageImpl.main_frame(this.actual_page)
    FrameImpl.expect(frame, expression, expect_options, title)
  end

  # upstream: PageAssertionsImpl.java:46
  def has_title(this, title, options) when is_binary(title) do
    expected = %ExpectedTextValue{}
    expected = %{expected | string: title}
    expected = %{expected | normalize_white_space: true}

    expect_impl(
      this,
      "to.have.title",
      expected,
      title,
      "Page title expected to be",
      Utils.convert_type(options, FrameExpectOptions),
      "Assert \"hasTitle\""
    )
  end

  # upstream: PageAssertionsImpl.java:54
  def has_title(this, %Regex{} = pattern, options) do
    expected = expected_regex(pattern)

    expect_impl(
      this,
      "to.have.title",
      expected,
      pattern,
      "Page title expected to match regex",
      Utils.convert_type(options, FrameExpectOptions),
      "Assert \"hasTitle\""
    )
  end

  # upstream: PageAssertionsImpl.java:60
  def has_url(this, url, options) when is_binary(url) do
    expected = %ExpectedTextValue{}
    base_url = BrowserContextImpl.base_url(PageImpl.context(this.actual_page))
    url = if base_url != nil, do: URI.merge(base_url, url) |> to_string(), else: url
    expected = %{expected | string: url}
    expected = %{expected | ignore_case: should_ignore_case(options)}

    expect_impl(
      this,
      "to.have.url",
      expected,
      url,
      "Page URL expected to be",
      Utils.convert_type(options, FrameExpectOptions),
      "Assert \"hasURL\""
    )
  end

  # upstream: PageAssertionsImpl.java:71
  def has_url(this, %Regex{} = pattern, options) do
    expected = expected_regex(pattern)

    expect_impl(
      this,
      "to.have.url",
      expected,
      pattern,
      "Page URL expected to match regex",
      Utils.convert_type(options, FrameExpectOptions),
      "Assert \"hasURL\""
    )
  end

  # upstream: PageAssertionsImpl.java:87
  def not_(this), do: new(this.actual_page, !this.is_not)
end
