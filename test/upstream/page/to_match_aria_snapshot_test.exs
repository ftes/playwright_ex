defmodule PlaywrightEx.Page.ToMatchAriaSnapshotTest do
  @upstream "tests/page/to-match-aria-snapshot.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Expect
  alias PlaywrightEx.Page

  @moduletag :page

  # `${/re/}` in a JS template literal renders the regex source between slashes.
  defp js_regex(regex), do: "/#{Regex.source(regex)}/"

  test "AR-107 should match page", %{page: page} do
    Page.set_content!(page, "<h1>title</h1>")

    Expect.to_match_aria_snapshot!(page, """
    - heading "title"
    """)
  end

  test "AR-108 should match page complex", %{page: page} do
    Page.set_content!(page, """
    <h1>Microsoft</h1>
    <div>Open source projects and samples from Microsoft</div>
    <ul>
      <li>
        <a href="about:blank">Playwright</a>
      </li>
    </ul>
    """)

    Expect.to_match_aria_snapshot!(page, """
    - heading "Microsoft"
    - text: Open source projects and samples from Microsoft
    - list:
      - listitem:
        - link "Playwright"
    """)
  end

  test "AR-109 should match page with not", %{page: page} do
    Page.set_content!(page, "<h1>title</h1>")

    Expect.not_to_match_aria_snapshot!(page, """
    - heading "wrong"
    """)
  end

  test "AR-110 should fail page with timeout", %{page: page} do
    Page.set_content!(page, "<h1>title</h1>")

    {:error, e} =
      Expect.to_match_aria_snapshot(
        page,
        """
        - heading "wrong"
        """,
        timeout: 2000
      )

    assert e.message =~ "expect(page).toMatchAriaSnapshot(expected) failed"
    assert e.message =~ "Timeout:  2000ms"
    refute e.message =~ "Locator"
  end

  test "AR-111 should match", %{page: page} do
    Page.set_content!(page, "<h1>title</h1>")

    Expect.to_match_aria_snapshot!(page, """
    - heading "title"
    """)

    # Elixir only: the suggested rebaseline is not written into the source, so an empty
    # snapshot fails with it instead of passing (Matchers.Expect).
    {:error, e} = Expect.to_match_aria_snapshot(page, "")
    assert e.message =~ "A snapshot is not provided, generating new baseline."
    assert e.message =~ ~s(- heading "title" [level=1])
  end

  test "AR-112 should match in list", %{page: page} do
    Page.set_content!(page, """
    <h1>title</h1>
    <h1>title 2</h1>
    """)

    Expect.to_match_aria_snapshot!(page, """
    - heading "title"
    """)
  end

  test "AR-113 should match list with accessible name", %{page: page} do
    Page.set_content!(page, """
    <ul aria-label="my list">
      <li>one</li>
      <li>two</li>
    </ul>
    """)

    Expect.to_match_aria_snapshot!(page, """
    - list "my list":
      - listitem: "one"
      - listitem: "two"
    """)
  end

  test "AR-114 should match deep item", %{page: page} do
    Page.set_content!(page, """
    <div>
      <h1>title</h1>
      <h1>title 2</h1>
    </div>
    """)

    Expect.to_match_aria_snapshot!(page, """
    - heading "title"
    """)
  end

  test "AR-115 should match complex", %{page: page} do
    Page.set_content!(page, """
    <ul>
      <li>
        <a href='about:blank'>link</a>
      </li>
    </ul>
    """)

    Expect.to_match_aria_snapshot!(page, """
    - list:
      - listitem:
        - link "link"
    """)
  end

  test "AR-116 should match regex", %{page: page} do
    Page.set_content!(page, "<h1>Issues 12</h1>")

    Expect.to_match_aria_snapshot!(page, """
    - heading #{js_regex(~r/Issues \d+/)}
    """)

    Page.set_content!(page, "<h1>Issues 1/2</h1>")

    Expect.to_match_aria_snapshot!(page, """
    - heading #{js_regex(~r{Issues 1[/]2})}
    """)

    Page.set_content!(page, "<h1>Issues 1[</h1>")

    Expect.to_match_aria_snapshot!(page, """
    - heading #{js_regex(~r/Issues 1\[/)}
    """)

    Page.set_content!(page, "<h1>Issues 1]]2</h1>")

    Expect.to_match_aria_snapshot!(page, """
    - heading #{js_regex(~r/Issues 1[\]]]2/)}
    """)
  end

  test "AR-117 should allow text nodes", %{page: page} do
    Page.set_content!(page, """
    <h1>Microsoft</h1>
    <div>Open source projects and samples from Microsoft</div>
    """)

    Expect.to_match_aria_snapshot!(page, """
    - heading "Microsoft"
    - text: "Open source projects and samples from Microsoft"
    """)
  end

  test "AR-118 details visibility", %{page: page} do
    Page.set_content!(page, """
    <details>
      <summary>Summary</summary>
      <div>Details</div>
    </details>
    """)

    Expect.to_match_aria_snapshot!(page, """
    - group: "Summary"
    """)
  end

  test "AR-119 checked attribute", %{page: page} do
    Page.set_content!(page, """
    <input type='checkbox' checked />
    """)

    Expect.to_match_aria_snapshot!(page, """
    - checkbox
    """)

    Expect.to_match_aria_snapshot!(page, """
    - checkbox [checked]
    """)

    Expect.to_match_aria_snapshot!(page, """
    - checkbox [checked=true]
    """)

    {:error, e} = Expect.to_match_aria_snapshot(page, "- checkbox [checked=false]\n", timeout: 1000)
    assert e.message =~ "expect(page).toMatchAriaSnapshot(expected) failed"
    assert e.message =~ "Timeout:  1000ms"

    {:error, e} = Expect.to_match_aria_snapshot(page, "- checkbox [checked=mixed]\n", timeout: 1000)
    assert e.message =~ "expect(page).toMatchAriaSnapshot(expected) failed"
    assert e.message =~ "Timeout:  1000ms"

    {:error, e} = Expect.to_match_aria_snapshot(page, "- checkbox [checked=5]\n", timeout: 1000)
    assert e.message =~ " attribute must be a boolean or \"mixed\""
  end

  test "AR-120 disabled attribute", %{page: page} do
    Page.set_content!(page, """
    <button disabled>Click me</button>
    """)

    Expect.to_match_aria_snapshot!(page, """
    - button
    """)

    Expect.to_match_aria_snapshot!(page, """
    - button [disabled]
    """)

    Expect.to_match_aria_snapshot!(page, """
    - button [disabled=true]
    """)

    {:error, e} = Expect.to_match_aria_snapshot(page, "- button [disabled=false]\n", timeout: 1000)
    assert e.message =~ "expect(page).toMatchAriaSnapshot(expected) failed"
    assert e.message =~ "Timeout:  1000ms"

    {:error, e} = Expect.to_match_aria_snapshot(page, "- button [disabled=invalid]\n", timeout: 1000)
    assert e.message =~ " attribute must be a boolean"
  end

  test "AR-121 expanded attribute", %{page: page} do
    Page.set_content!(page, """
    <button aria-expanded="true">Toggle</button>
    """)

    Expect.to_match_aria_snapshot!(page, """
    - button
    """)

    Expect.to_match_aria_snapshot!(page, """
    - button [expanded]
    """)

    Expect.to_match_aria_snapshot!(page, """
    - button [expanded=true]
    """)

    {:error, e} = Expect.to_match_aria_snapshot(page, "- button [expanded=false]\n", timeout: 1000)
    assert e.message =~ "expect(page).toMatchAriaSnapshot(expected) failed"
    assert e.message =~ "Timeout:  1000ms"

    {:error, e} = Expect.to_match_aria_snapshot(page, "- button [expanded=invalid]\n", timeout: 1000)
    assert e.message =~ " attribute must be a boolean"
  end

  test "AR-122 level attribute", %{page: page} do
    Page.set_content!(page, """
    <h2>Section Title</h2>
    """)

    Expect.to_match_aria_snapshot!(page, """
    - heading
    """)

    Expect.to_match_aria_snapshot!(page, """
    - heading [level=2]
    """)

    {:error, e} = Expect.to_match_aria_snapshot(page, "- heading [level=3]\n", timeout: 1000)
    assert e.message =~ "expect(page).toMatchAriaSnapshot(expected) failed"
    assert e.message =~ "Timeout:  1000ms"

    {:error, e} = Expect.to_match_aria_snapshot(page, "- heading [level=two]\n", timeout: 1000)
    assert e.message =~ " attribute must be a number"
  end

  test "AR-123 pressed attribute", %{page: page} do
    Page.set_content!(page, """
    <button aria-pressed="true">Like</button>
    """)

    Expect.to_match_aria_snapshot!(page, """
    - button
    """)

    Expect.to_match_aria_snapshot!(page, """
    - button [pressed]
    """)

    Expect.to_match_aria_snapshot!(page, """
    - button [pressed=true]
    """)

    {:error, e} = Expect.to_match_aria_snapshot(page, "- button [pressed=false]\n", timeout: 1000)
    assert e.message =~ "expect(page).toMatchAriaSnapshot(expected) failed"
    assert e.message =~ "Timeout:  1000ms"

    # Test for 'mixed' state
    Page.set_content!(page, """
    <button aria-pressed="mixed">Like</button>
    """)

    Expect.to_match_aria_snapshot!(page, """
    - button [pressed=mixed]
    """)

    {:error, e} = Expect.to_match_aria_snapshot(page, "- button [pressed=true]\n", timeout: 1000)
    assert e.message =~ "expect(page).toMatchAriaSnapshot(expected) failed"
    assert e.message =~ "Timeout:  1000ms"

    {:error, e} = Expect.to_match_aria_snapshot(page, "- button [pressed=5]\n", timeout: 1000)
    assert e.message =~ " attribute must be a boolean or \"mixed\""
  end

  test "AR-124 selected attribute", %{page: page} do
    Page.set_content!(page, """
    <table>
      <tr aria-selected="true">
        <td>Row</td>
      </tr>
      <tr>
        <td>Row 2</td>
      </tr>
    </table>
    """)

    Expect.to_match_aria_snapshot!(page, """
    - row
    - row
    """)

    Expect.to_match_aria_snapshot!(page, """
    - row [selected]
    - row
    """)

    Expect.to_match_aria_snapshot!(page, """
    - row [selected=true]
    - row [selected=false]
    """)

    Expect.to_match_aria_snapshot!(Page.locator(page, "table"), """
    - table:
      - rowgroup:
        - row [selected=true]
        - row [selected=false]
    """)

    {:error, e} =
      Expect.to_match_aria_snapshot(
        page,
        """
        - row [selected=false]
        - row [selected=false]
        """,
        timeout: 1000
      )

    assert e.message =~ """
           expect(page).toMatchAriaSnapshot(expected) failed

           Timeout: 1000ms
           - Expected  - 2
           + Received  + 6

           - - row [selected=false]
           - - row [selected=false]
           + - table:
           +   - rowgroup:
           +     - row "Row" [selected]:
           +       - cell "Row"
           +     - row \"Row 2\":
           +       - cell \"Row 2\"

           Call log:
           """

    {:error, e} = Expect.to_match_aria_snapshot(page, "- row [selected=invalid]\n", timeout: 1000)
    assert e.message =~ " attribute must be a boolean"
  end

  test "AR-125 integration test", %{page: page} do
    Page.set_content!(page, """
    <h1>Microsoft</h1>
    <div>Open source projects and samples from Microsoft</div>
    <ul>
      <li>
        <details>
          <summary>
            Verified
          </summary>
          <div>
            <div>
              <p>
                We've verified that the organization <strong>microsoft</strong> controls the domain:
              </p>
              <ul>
                <li class="mb-1">
                  <strong>opensource.microsoft.com</strong>
                </li>
              </ul>
              <div>
                <a href="about: blank">Learn more about verified organizations</a>
              </div>
            </div>
          </div>
        </details>
      </li>
      <li>
        <a href="about:blank">
          <summary title="Label: GitHub Sponsor">Sponsor</summary>
        </a>
      </li>
    </ul>
    """)

    Expect.to_match_aria_snapshot!(page, """
    - heading "Microsoft"
    - text: Open source projects and samples from Microsoft
    - list:
      - listitem:
        - group: Verified
      - listitem:
        - link "Sponsor"
    """)
  end

  test "AR-126 integration test 2", %{page: page} do
    Page.set_content!(page, """
    <div>
      <header>
        <h1>todos</h1>
        <input placeholder="What needs to be done?">
      </header>
    </div>
    """)

    Expect.to_match_aria_snapshot!(page, """
    - heading "todos"
    - textbox "What needs to be done?"
    """)
  end

  test "AR-127 expected formatter", %{page: page} do
    Page.set_content!(page, """
    <div>
      <header>
        <h1>todos</h1>
        <input placeholder="What needs to be done?">
        <button>Time 15:30</button>
      </header>
    </div>
    """)

    {:error, error} =
      Expect.to_match_aria_snapshot(
        page,
        """
        - heading "todos"
        - textbox "Wrong text"
        """,
        timeout: 1
      )

    # Note that error message should not contain any regular expressions,
    # unlike the baseline generated by --update-snapshots.
    assert error.message =~ """
           expect(page).toMatchAriaSnapshot(expected) failed

           Timeout: 1ms
           - Expected  - 2
           + Received  + 4

           - - heading "todos"
           - - textbox "Wrong text"
           + - banner:
           +   - heading "todos" [level=1]
           +   - textbox "What needs to be done?"
           +   - button "Time 15:30"

           Call log:
           """
  end

  test "AR-128 should unpack escaped names", %{page: page} do
    Page.set_content!(page, """
    <button>Click: me</button>
    """)

    Expect.to_match_aria_snapshot!(page, """
    - 'button "Click: me"'
    """)

    Expect.to_match_aria_snapshot!(page, """
    - 'button /Click: me/'
    """)

    Page.set_content!(page, """
    <button>Click / me</button>
    """)

    Expect.to_match_aria_snapshot!(page, """
    - button "Click / me"
    """)

    Expect.to_match_aria_snapshot!(page, """
    - button /Click \\/ me/
    """)

    Expect.to_match_aria_snapshot!(page, """
    - 'button /Click \\/ me/'
    """)

    Page.set_content!(page, """
    <button>Click " me</button>
    """)

    Expect.to_match_aria_snapshot!(page, """
    - button "Click \\\" me"
    """)

    Expect.to_match_aria_snapshot!(page, """
    - button /Click \" me/
    """)

    Expect.to_match_aria_snapshot!(page, """
    - button /Click \\\" me/
    """)

    Page.set_content!(page, """
    <button>Click \\ me</button>
    """)

    Expect.to_match_aria_snapshot!(page, """
    - button "Click \\\\ me"
    """)

    Expect.to_match_aria_snapshot!(page, """
    - button /Click \\\\ me/
    """)

    Expect.to_match_aria_snapshot!(page, """
    - 'button /Click \\\\ me/'
    """)

    Page.set_content!(page, """
    <button>Click ' me</button>
    """)

    Expect.to_match_aria_snapshot!(page, """
    - 'button "Click '' me"'
    """)

    Page.set_content!(page, """
    <h1>heading "name" [level=1]</h1>
    """)

    Expect.to_match_aria_snapshot!(page, """
    - heading "heading \\"name\\" [level=1]" [level=1]
    """)

    Page.set_content!(page, """
    <h1>heading \\" [level=2]</h1>
    """)

    Expect.to_match_aria_snapshot!(page, """
    - |
        heading    "heading \\\\\\" [level=2]" [
           level  =   1   ]
    """)
  end

  test "AR-129 should report error in YAML", %{page: page} do
    Page.set_content!(page, "<h1>title</h1>")

    {:error, error} =
      Expect.to_match_aria_snapshot(page, """
      heading "title"
      """)

    assert error.message == """
           expect(page).toMatchAriaSnapshot(expected) failed

           Expected: "heading \\"title\\""
           Error: Aria snapshot must be a YAML sequence, elements starting with " -"

           Call log:
             - Expect "toMatchAriaSnapshot" with timeout 10000ms
           """

    {:error, error} =
      Expect.to_match_aria_snapshot(page, """
      - heading: a:
      """)

    assert error.message == """
           expect(page).toMatchAriaSnapshot(expected) failed

           Expected: "- heading: a:"
           Error: Nested mappings are not allowed in compact mappings at line 1, column 12:

           - heading: a:
                      ^

           Call log:
             - Expect "toMatchAriaSnapshot" with timeout 10000ms
           """
  end

  test "AR-130 should report error in YAML keys", %{page: page} do
    Page.set_content!(page, "<h1>title</h1>")

    {:error, error} =
      Expect.to_match_aria_snapshot(page, """
      - heading "title
      """)

    assert error.message == """
           expect(page).toMatchAriaSnapshot(expected) failed

           Expected: "- heading \\"title"
           Error: Unterminated string:

           heading "title
                         ^

           Call log:
             - Expect "toMatchAriaSnapshot" with timeout 10000ms
           """

    {:error, error} =
      Expect.to_match_aria_snapshot(page, """
      - heading /title
      """)

    assert error.message == """
           expect(page).toMatchAriaSnapshot(expected) failed

           Expected: "- heading /title"
           Error: Unterminated regex:

           heading /title
                         ^

           Call log:
             - Expect "toMatchAriaSnapshot" with timeout 10000ms
           """

    {:error, error} =
      Expect.to_match_aria_snapshot(page, """
      - heading [level=a]
      """)

    assert error.message == """
           expect(page).toMatchAriaSnapshot(expected) failed

           Expected: "- heading [level=a]"
           Error: Value of "level" attribute must be a number:

           heading [level=a]
                          ^

           Call log:
             - Expect "toMatchAriaSnapshot" with timeout 10000ms
           """

    {:error, error} =
      Expect.to_match_aria_snapshot(page, """
      - heading [expanded=FALSE]
      """)

    assert error.message == """
           expect(page).toMatchAriaSnapshot(expected) failed

           Expected: "- heading [expanded=FALSE]"
           Error: Value of "expanded" attribute must be a boolean:

           heading [expanded=FALSE]
                             ^

           Call log:
             - Expect "toMatchAriaSnapshot" with timeout 10000ms
           """

    {:error, error} =
      Expect.to_match_aria_snapshot(page, """
      - heading [checked=foo]
      """)

    assert error.message == """
           expect(page).toMatchAriaSnapshot(expected) failed

           Expected: "- heading [checked=foo]"
           Error: Value of "checked" attribute must be a boolean or "mixed":

           heading [checked=foo]
                            ^

           Call log:
             - Expect "toMatchAriaSnapshot" with timeout 10000ms
           """

    {:error, error} =
      Expect.to_match_aria_snapshot(page, """
      - heading [level=]
      """)

    assert error.message == """
           expect(page).toMatchAriaSnapshot(expected) failed

           Expected: "- heading [level=]"
           Error: Value of "level" attribute must be a number:

           heading [level=]
                          ^

           Call log:
             - Expect "toMatchAriaSnapshot" with timeout 10000ms
           """

    {:error, error} =
      Expect.to_match_aria_snapshot(page, """
      - heading [bogus]
      """)

    assert error.message == """
           expect(page).toMatchAriaSnapshot(expected) failed

           Expected: "- heading [bogus]"
           Error: Unsupported attribute [bogus]:

           heading [bogus]
                    ^

           Call log:
             - Expect "toMatchAriaSnapshot" with timeout 10000ms
           """

    {:error, error} =
      Expect.to_match_aria_snapshot(page, """
      - heading invalid
      """)

    assert error.message == """
           expect(page).toMatchAriaSnapshot(expected) failed

           Expected: "- heading invalid"
           Error: Unexpected input:

           heading invalid
                   ^

           Call log:
             - Expect "toMatchAriaSnapshot" with timeout 10000ms
           """
  end

  test "AR-131 call log should contain actual snapshot", %{page: page} do
    Page.set_content!(page, "<h1>todos</h1>")

    {:error, error} =
      Expect.to_match_aria_snapshot(
        page,
        """
        - heading "wrong"
        """,
        timeout: 3000
      )

    assert error.message =~ ~s(unexpected value "- heading "todos" [level=1]")
  end

  test "AR-132 should parse attributes", %{page: page} do
    Page.set_content!(page, """
    <button aria-pressed="mixed">hello world</button>
    """)

    Expect.to_match_aria_snapshot!(page, """
    - button [pressed=mixed ]
    """)

    Page.set_content!(page, """
    <h2>hello world</h2>
    """)

    Expect.not_to_match_aria_snapshot!(Page.locator(page, "body"), """
    - heading [level =  -3 ]
    """)
  end

  test "AR-133 should not unshift actual template text", %{page: page} do
    Page.set_content!(page, """
    <h1>title</h1>
    <h1>title 2</h1>
    """)

    # The exact JS template literal, including its leading/trailing whitespace.
    expected =
      "\n        - heading \"title\" [level=1]\n    - heading \"title 2\" [level=1]\n  "

    {:error, error} = Expect.to_match_aria_snapshot(page, expected, timeout: 1000)

    assert error.message =~
             "\n    - heading \"title\" [level=1]\n- heading \"title 2\" [level=1]"
  end

  test "AR-134 should not match what is not matched", %{page: page} do
    Page.set_content!(page, "<p>Text</p>")

    {:error, error} =
      Expect.to_match_aria_snapshot(page, """
      - paragraph:
        - button "bogus"
      """)

    assert error.message =~ """

           - - paragraph:
           -   - button "bogus"
           + - paragraph: Text\
           """
  end

  test "AR-135 should match url", %{page: page} do
    Page.set_content!(page, """
    <a href='https://example.com'>Link</a>
    """)

    Expect.to_match_aria_snapshot!(page, """
    - link:
      - /url: /.*example.com/
    """)
  end

  test "AR-136 should detect unexpected children: equal", %{page: page} do
    Page.set_content!(page, """
    <ul>
      <li>One</li>
      <li>Two</li>
      <li>Three</li>
    </ul>
    """)

    Expect.to_match_aria_snapshot!(page, """
    - list:
      - listitem: "One"
      - listitem: "Three"
    """)

    {:error, e} =
      Expect.to_match_aria_snapshot(
        page,
        """
        - list:
          - /children: equal
          - listitem: "One"
          - listitem: "Three"
        """,
        timeout: 1000
      )

    assert e.message =~ "expect(page).toMatchAriaSnapshot(expected) failed"
    assert e.message =~ "+   - listitem: Two"
  end

  test "AR-137 should detect unexpected children: deep-equal", %{page: page} do
    Page.set_content!(page, """
    <ul>
      <li>
        <ul>
          <li>1.1</li>
          <li>1.2</li>
        </ul>
      </li>
    </ul>
    """)

    Expect.to_match_aria_snapshot!(page, """
    - list:
      - listitem:
        - list:
          - listitem: 1.1
    """)

    Expect.to_match_aria_snapshot!(page, """
    - list:
      - /children: equal
      - listitem:
        - list:
          - listitem: 1.1
    """)

    {:error, e} =
      Expect.to_match_aria_snapshot(
        page,
        """
        - list:
          - /children: deep-equal
          - listitem:
            - list:
              - listitem: 1.1
        """,
        timeout: 1000
      )

    assert e.message =~ "expect(page).toMatchAriaSnapshot(expected) failed"
    assert e.message =~ "+       - listitem: \"1.2\""
  end

  test "AR-138 should allow restoring contain mode inside deep-equal", %{page: page} do
    Page.set_content!(page, """
    <ul>
      <li>
        <ul>
          <li>1.1</li>
          <li>1.2</li>
        </ul>
      </li>
    </ul>
    """)

    {:error, e} =
      Expect.to_match_aria_snapshot(
        page,
        """
        - list:
          - /children: deep-equal
          - listitem:
            - list:
              - listitem: 1.1
        """,
        timeout: 1000
      )

    assert e.message =~ "expect(page).toMatchAriaSnapshot(expected) failed"
    assert e.message =~ "+       - listitem: \"1.2\""

    Expect.to_match_aria_snapshot!(page, """
    - list:
      - /children: deep-equal
      - listitem:
        - list:
          - /children: contain
          - listitem: 1.1
    """)
  end

  test "AR-139 top-level deep-equal", %{page: page} do
    # issue: https://github.com/microsoft/playwright/issues/36456
    Page.set_content!(page, """
    <ul>
      <li>
        <ul>
          <li>1.1</li>
          <li>1.2</li>
        </ul>
      </li>
    </ul>
    """)

    {:error, error} =
      Expect.to_match_aria_snapshot(
        page,
        """
        - /children: deep-equal
        - list
        """,
        timeout: 1000
      )

    assert error.message =~
             String.trim("""
             - - /children: deep-equal
             - - list
             + - list:
             +   - listitem:
             +     - list:
             +       - listitem: "1.1"
             +       - listitem: "1.2"
             """)
  end

  test "AR-140 generated snapshot includes text children when name is longer than text", %{page: page} do
    # issue: https://github.com/microsoft/playwright/issues/40079
    Page.set_content!(page, """
    <section>
      <div role="progressbar" aria-label="Alpha Beta" aria-valuenow="7" aria-valuemin="0" aria-valuemax="10">
        <span>Alpha</span>
        <span>7</span>
      </div>
    </section>
    """)

    Expect.to_match_aria_snapshot!(Page.locator(page, "section"), """
    - /children: deep-equal
    - progressbar "Alpha Beta": Alpha 7
    """)
  end

  test "AR-141 treat bad regex as a string", %{page: page} do
    Page.set_content!(page, ~s(<a href="/foo">Log in</a>))

    {:error, error} =
      Expect.to_match_aria_snapshot(
        page,
        """
        - link "Log in":
          - /url: /[a/
        """,
        timeout: 1
      )

    assert error.message =~ "expect(page).toMatchAriaSnapshot(expected) failed"
    assert error.message =~ "-   - /url: /[a/"
    assert error.message =~ "+   - /url: /foo"
  end

  test "AR-142 invalid attribute", %{page: page} do
    # issue: https://github.com/microsoft/playwright/issues/34839
    Page.set_content!(page, """
    <input type="text" aria-label="Email" aria-invalid="true" value="not-an-email">
    <input type="text" aria-label="Name" value="Alice">
    """)

    Expect.to_match_aria_snapshot!(page, """
    - textbox "Email" [invalid]: not-an-email
    - textbox "Name": Alice
    """)

    Expect.to_match_aria_snapshot!(page, """
    - textbox "Email" [invalid=true]: not-an-email
    - textbox "Name" [invalid=false]: Alice
    """)

    # `aria-invalid="grammar"` and `aria-invalid="spelling"` surface their underlying value.
    Page.set_content!(page, """
    <input type="text" aria-label="Bio" aria-invalid="grammar">
    <input type="text" aria-label="Note" aria-invalid="spelling">
    <input type="text" aria-label="Mixed-case grammar" aria-invalid="Grammar">
    <input type="text" aria-label="Mixed-case spelling" aria-invalid="Spelling">
    """)

    Expect.to_match_aria_snapshot!(page, """
    - textbox "Bio" [invalid=grammar]
    - textbox "Note" [invalid=spelling]
    - textbox "Mixed-case grammar" [invalid=grammar]
    - textbox "Mixed-case spelling" [invalid=spelling]
    """)

    # A `grammar` value is distinct from a plain `true` invalid state.
    {:error, error} =
      Expect.to_match_aria_snapshot(
        page,
        """
        - textbox "Bio" [invalid]
        """,
        timeout: 1
      )

    assert error.message =~ "[invalid=grammar]"

    # Any other non-false value falls back to `true`.
    Page.set_content!(page, ~s(<input type="text" aria-label="Zip" aria-invalid="garbage">))

    Expect.to_match_aria_snapshot!(page, """
    - textbox "Zip" [invalid]
    """)
  end
end
