defmodule PlaywrightEx.RouteMatcherTest do
  use ExUnit.Case, async: true

  alias PlaywrightEx.RouteMatcher

  test "Playwright globs match the full URL with literal question marks" do
    for {glob, url, expected} <- [
          {"**/*.js", "https://example.test/a.js", true},
          {"**/*.js", "https://example.test/a.js?x=1", false},
          {"https://example.test/*", "https://example.test/a/b", false},
          {"https://example.test/**", "https://example.test/a/b", true},
          {"**/forms/js.php/**", "https://example.test/forms/js.php/123", true},
          {"https://example.test/**/a", "https://example.test/a", true},
          {"**/*.{png,jpg}", "https://example.test/a.jpg", true},
          {"**/*.{png,jpg}", "https://example.test/a.gif", false},
          {"**/a?b", "https://example.test/a?b", true},
          {"**/a?b", "https://example.test/axb", false},
          {"**/a\\*", "https://example.test/a*", true},
          {"**/a\\*", "https://example.test/abc", false}
        ] do
      assert Regex.match?(RouteMatcher.compile(glob), url) == expected, inspect({glob, url})
    end
  end

  test "regexes retain Elixir semantics and invalid groups are rejected" do
    assert Regex.match?(RouteMatcher.compile(~r/HELLO/i), "https://example.test/hello")

    for glob <- ["{unclosed", "nested{a,{b,c}}", "unmatched}"] do
      assert_raise ArgumentError, fn -> RouteMatcher.compile(glob) end
    end
  end
end
