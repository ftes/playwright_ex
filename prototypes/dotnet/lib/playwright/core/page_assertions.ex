defmodule Playwright.Core.PageAssertions do
  @moduledoc "upstream: Core/PageAssertions.cs"
  @behaviour Playwright.Core.AssertionsBase

  alias Playwright.Core.BrowserContext
  alias Playwright.Core.Frame
  alias Playwright.Core.Page
  alias Playwright.Helpers.URLMatch
  alias Playwright.Transport.ChannelOwner
  alias Playwright.Transport.Protocol.ExpectedTextValue
  import Playwright.Core.AssertionsBase

  defstruct [:page, :is_not, :custom_message]

  # upstream: Core/PageAssertions.cs:36
  def new(page, is_not, custom_message \\ nil), do: %__MODULE__{page: page, is_not: is_not, custom_message: custom_message}

  # upstream: Core/PageAssertions.cs:41
  def not_(this), do: new(this.page, !this.is_not, this.custom_message)

  # upstream: Core/PageAssertions.cs:43
  @impl true
  def call_expect_async(this, expression, expect_options, title) do
    frame = Page.main_frame(this.page)
    ChannelOwner.wrap_api_call(
      frame,
      fn -> Frame.expect_async(frame, nil, expression, expect_options) end,
      false,
      title)
  end

  # upstream: Core/PageAssertions.cs:53 + :56
  def to_have_title_async(this, title_or_reg_exp, options \\ nil)

  def to_have_title_async(this, %Regex{} = title_or_reg_exp, options) do
    expect_impl_async(this, "to.have.title", expected_regex(title_or_reg_exp, %ExpectedTextValue{normalize_white_space: true}), title_or_reg_exp, "Page title expected to be", "Expect \"ToHaveTitleAsync\"", convert_to_frame_expect_options(options))
  end

  def to_have_title_async(this, title_or_reg_exp, options) do
    expect_impl_async(this, "to.have.title", %ExpectedTextValue{string: title_or_reg_exp, normalize_white_space: true}, title_or_reg_exp, "Page title expected to be", "Expect \"ToHaveTitleAsync\"", convert_to_frame_expect_options(options))
  end

  # upstream: Core/PageAssertions.cs:59 + :62
  def to_have_url_async(this, url_or_reg_exp, options \\ nil)

  def to_have_url_async(this, %Regex{} = url_or_reg_exp, options) do
    expect_impl_async(this, "to.have.url", expected_regex(url_or_reg_exp, %ExpectedTextValue{ignore_case: options[:ignore_case]}), url_or_reg_exp, "Page URL expected to match regex", "Expect \"ToHaveURLAsync\"", convert_to_frame_expect_options(options))
  end

  def to_have_url_async(this, url_or_reg_exp, options) do
    expect_impl_async(this, "to.have.url", %ExpectedTextValue{string: URLMatch.construct_url_based_on_base_url(BrowserContext.base_url(Page.context(this.page)), url_or_reg_exp), ignore_case: options[:ignore_case]}, url_or_reg_exp, "Page URL expected to be", "Expect \"ToHaveURLAsync\"", convert_to_frame_expect_options(options))
  end
end
