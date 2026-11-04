defmodule Playwright.Impl.UrlMatcher do
  # upstream: UrlMatcher.java:29
  alias Playwright.Impl.{ChannelOwner, Utils}
  alias Playwright.PlaywrightException

  defstruct [:glob, :pattern, :predicate]

  # upstream: UrlMatcher.java:34
  def for_one_of(base_url, object, local_utils, is_web_socket_url) do
    cond do
      object == nil ->
        %__MODULE__{}

      is_binary(object) ->
        for_glob(base_url, object, local_utils, is_web_socket_url)

      is_struct(object, Regex) ->
        new(object)

      is_function(object, 1) ->
        new(object)

      true ->
        raise PlaywrightException,
          message: "Url must be String, Pattern or Predicate<String>, found: #{inspect(object)}"
    end
  end

  # upstream: UrlMatcher.java:66
  def for_glob(base_url, glob, local_utils, is_web_socket_url) do
    pattern =
      glob_to_regex(local_utils, glob, if(base_url != nil, do: to_string(base_url), else: nil), is_web_socket_url)

    %__MODULE__{glob: glob, pattern: pattern}
  end

  # LocalUtils.globToRegex (upstream: LocalUtils.java)
  defp glob_to_regex(local_utils, glob, base_url, web_socket_url) do
    params = %{"glob" => glob, "webSocketUrl" => web_socket_url}
    params = if base_url != nil, do: Map.put(params, "baseURL", base_url), else: params
    json = ChannelOwner.send_message(local_utils, "globToRegex", params, nil)
    Regex.compile!(json["regex"])
  end

  # upstream: UrlMatcher.java:71 / :75
  def new(%Regex{} = pattern), do: %__MODULE__{pattern: pattern}
  def new(predicate) when is_function(predicate, 1), do: %__MODULE__{predicate: predicate}

  # upstream: UrlMatcher.java:85
  def test(this, value) do
    cond do
      this.pattern != nil -> Regex.match?(this.pattern, value)
      this.predicate != nil -> this.predicate.(value)
      true -> true
    end
  end

  defimpl String.Chars do
    # upstream: UrlMatcher.java:127
    def to_string(this) do
      cond do
        this.glob != nil ->
          "<glob pattern=\"#{this.glob}\">"

        this.pattern != nil ->
          "<regex pattern=\"#{Regex.source(this.pattern)}\" flags=\"#{Utils.to_js_regex_flags(this.pattern)}\">"

        this.predicate != nil ->
          "<predicate>"

        true ->
          "<true>"
      end
    end
  end
end
