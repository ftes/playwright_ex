defmodule PlaywrightEx.Page.PageEvaluateTest do
  @upstream "tests/page/page-evaluate.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  @browser_name System.get_env("BROWSER", "chromium")

  import PlaywrightEx.Utils, only: [attach_frame: 3, detach_frame: 2]

  alias PlaywrightEx.Frame
  alias PlaywrightEx.JSHandle
  alias PlaywrightEx.Page
  alias PlaywrightEx.Protocol.Serializers.JSError
  alias PlaywrightEx.TestServer

  @moduletag :page

  defp message({:error, error}), do: Exception.message(error)

  # `Error` created in the test process: `e.stack` holds this function's frame.
  defp inner_function do
    {:current_stacktrace, stacktrace} = Process.info(self(), :current_stacktrace)
    %JSError{name: "foobar", message: "error message", stack: Exception.format_stacktrace(stacktrace)}
  end

  test "should work @smoke", %{page: page} do
    result = Page.evaluate!(page, "() => 7 * 3")
    assert result == 21
  end

  test "should transfer NaN", %{page: page} do
    result = Page.evaluate!(page, "a => a", :nan)
    assert result === :nan
  end

  test "should transfer -0", %{page: page} do
    result = Page.evaluate!(page, "a => a", -0.0)
    assert result === -0.0
  end

  test "should transfer Infinity", %{page: page} do
    result = Page.evaluate!(page, "a => a", :infinity)
    assert result === :infinity
  end

  test "should transfer -Infinity", %{page: page} do
    result = Page.evaluate!(page, "a => a", :neg_infinity)
    assert result === :neg_infinity
  end

  test "should roundtrip unserializable values", %{page: page} do
    value = %{"infinity" => :infinity, "nInfinity" => :neg_infinity, "nZero" => -0.0, "nan" => :nan}
    result = Page.evaluate!(page, "value => value", value)
    assert result === value
  end

  test "should roundtrip promise to value", %{page: page} do
    assert Page.evaluate!(page, "value => Promise.resolve(value)", :null) === :null
    assert Page.evaluate!(page, "value => Promise.resolve(value)", :infinity) === :infinity
    assert Page.evaluate!(page, "value => Promise.resolve(value)", -0.0) === -0.0
    assert Page.evaluate!(page, "value => Promise.resolve(value)", nil) === nil
  end

  test "should roundtrip promise to unserializable values", %{page: page} do
    value = %{"infinity" => :infinity, "nInfinity" => :neg_infinity, "nZero" => -0.0, "nan" => :nan}
    result = Page.evaluate!(page, "value => Promise.resolve(value)", value)
    assert result === value
  end

  test "should transfer arrays", %{page: page} do
    result = Page.evaluate!(page, "a => a", [1, 2, 3])
    assert result == [1, 2, 3]
  end

  test "should transfer arrays as arrays, not objects", %{page: page} do
    result = Page.evaluate!(page, "a => Array.isArray(a)", [1, 2, 3])
    assert result == true
  end

  @tag skip: "not ported: typed arrays (Elixir has none to serialize; they parse to lists)"
  test "should transfer typed arrays"

  test "should transfer bigint", %{page: page} do
    # A bigint parses to an integer; 17 is a safe integer, so it travels as a number.
    assert Page.evaluate!(page, "() => 42n") == 42
    assert Page.evaluate!(page, "a => a", 17) == 17
  end

  test "should transfer maps as empty objects", %{page: page} do
    # `page.evaluate(a => ..., { x: new Map([[1, 2]]) })`  -- not ported: an Elixir map is an object
    assert Page.evaluate!(page, "() => new Map([[1, 2]])") == %{}
  end

  test "should transfer sets as empty objects", %{page: page} do
    # `page.evaluate(a => ..., { x: new Set([1, 2]) })`  -- not ported: no Elixir value serializes as a Set
    assert Page.evaluate!(page, "() => new Set([1, 2])") == %{}
  end

  test "should modify global environment", %{page: page} do
    Page.evaluate!(page, "() => window['globalVar'] = 123")
    assert Page.evaluate!(page, "globalVar") == 123
  end

  test "should evaluate in the page context", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/global-var.html")
    assert Page.evaluate!(page, "globalVar") == 123
  end

  test "should return undefined for objects with symbols", %{page: page} do
    assert Page.evaluate!(page, "() => [Symbol('foo4')]") == [nil]

    assert Page.evaluate!(page, """
           () => {
             const a = {};
             a[Symbol('foo4')] = 42;
             return a;
           }
           """) == %{}

    assert Page.evaluate!(page, """
           () => {
             return { foo: [{ a: Symbol('foo4') }] };
           }
           """) == %{"foo" => [%{"a" => nil}]}
  end

  @tag skip: "not ported: method shorthand source needs isFunction (page functions are JS source, PLAN)"
  test "should work with function shorthands"

  test "should work with unicode chars", %{page: page} do
    result = Page.evaluate!(page, "a => a['中文字符']", %{"中文字符" => 42})
    assert result == 42
  end

  test "should work with large strings", %{page: page} do
    expected = String.duplicate("x", 40_000)
    assert Page.evaluate!(page, "data => data", expected) == expected
  end

  test "should work with large unicode strings", %{page: page} do
    # issue: https://github.com/microsoft/playwright/issues/16367
    expected = String.duplicate("🎭", 10_000)
    assert Page.evaluate!(page, "data => data", expected) == expected
  end

  test "should throw when evaluation triggers reload", %{page: page} do
    error =
      Page.evaluate(page, """
      () => {
        location.reload();
        return new Promise(() => { });
      }
      """)

    assert message(error) =~ "navigation"
  end

  test "should await promise", %{page: page} do
    result = Page.evaluate!(page, "() => Promise.resolve(8 * 7)")
    assert result == 56
  end

  test "should work right after framenavigated", %{page: page, server: server} do
    me = self()
    Page.on(page, :frame_navigated, fn frame -> send(me, {:frame_evaluation, Frame.evaluate(frame, "() => 6 * 7")}) end)
    Page.goto!(page, server.empty_page)
    # `await frameEvaluation`: no timeout of its own.
    assert_receive {:frame_evaluation, {:ok, 42}}, 30_000
  end

  test "should work right after a cross-origin navigation", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    me = self()
    Page.on(page, :frame_navigated, fn frame -> send(me, {:frame_evaluation, Frame.evaluate(frame, "() => 6 * 7")}) end)
    Page.goto!(page, server.cross_process_prefix <> "/empty.html")
    # `await frameEvaluation`: no timeout of its own.
    assert_receive {:frame_evaluation, {:ok, 42}}, 30_000
  end

  test "should work from-inside an exposed function", %{page: page} do
    # Setup inpage callback, which calls Page.evaluate
    Page.expose_function!(page, "callController", fn a, b ->
      Page.evaluate!(page, "({ a, b }) => a * b", %{a: a, b: b})
    end)

    result =
      Page.evaluate!(page, """
      async function() {
        return await window['callController'](9, 3);
      }
      """)

    assert result == 27
  end

  test "should reject promise with exception", %{page: page} do
    error = Page.evaluate(page, "() => not_existing_object.property")
    assert {:error, _} = error
    assert message(error) =~ "not_existing_object"
  end

  test "should support thrown strings as error messages", %{page: page} do
    error = Page.evaluate(page, "() => { throw 'qwerty'; }")
    assert {:error, _} = error
    assert message(error) =~ "qwerty"
  end

  test "should support thrown numbers as error messages", %{page: page} do
    error = Page.evaluate(page, "() => { throw 100500; }")
    assert {:error, _} = error
    assert message(error) =~ "100500"
  end

  test "should reject when a falsy value is thrown", %{page: page} do
    # issue: https://github.com/microsoft/playwright/issues/42661
    for value <- ["null", "undefined", "0", "''", "false", "NaN", "-0", "0n"] do
      assert {:error, error} = Page.evaluate(page, "(() => { throw #{value}; })()"), "throw #{value}"
      assert is_exception(error), "throw #{value}"
      assert {:error, rejection} = Page.evaluate(page, "Promise.reject(#{value})"), "Promise.reject(#{value})"
      assert is_exception(rejection), "Promise.reject(#{value})"
    end
  end

  test "should include a non-error rejection value in the error message", %{page: page} do
    # issue: https://github.com/microsoft/playwright/issues/42661
    error = Page.evaluate(page, "() => Promise.reject(7)")
    assert message(error) =~ "7"
    null_error = Page.evaluate(page, "() => { throw null; }")
    assert message(null_error) =~ "null"
  end

  test "should return complex objects", %{page: page} do
    object = %{"foo" => "bar!"}
    result = Page.evaluate!(page, "a => a", object)
    # expect(result).not.toBe(object)  -- not ported: Elixir terms have no identity
    assert result == object
  end

  test "should return NaN", %{page: page} do
    result = Page.evaluate!(page, "() => NaN")
    assert result === :nan
  end

  test "should return -0", %{page: page} do
    result = Page.evaluate!(page, "() => -0")
    assert result === -0.0
  end

  test "should return Infinity", %{page: page} do
    result = Page.evaluate!(page, "() => Infinity")
    assert result === :infinity
  end

  test "should return -Infinity", %{page: page} do
    result = Page.evaluate!(page, "() => -Infinity")
    assert result === :neg_infinity
  end

  test "should work with overwritten Promise", %{page: page} do
    Page.evaluate!(page, """
    () => {
      const originalPromise = window.Promise;
      class Promise2 {
        static all(arg) {
          return wrap(originalPromise.all(arg));
        }
        static race(arg) {
          return wrap(originalPromise.race(arg));
        }
        static resolve(arg) {
          return wrap(originalPromise.resolve(arg));
        }
        constructor(f) {
          this._promise = new originalPromise(f);
        }
        then(f, r) {
          return wrap(this._promise.then(f, r));
        }
        catch(f) {
          return wrap(this._promise.catch(f));
        }
        finally(f) {
          return wrap(this._promise.finally(f));
        }
      }
      const wrap = p => {
        const result = new Promise2(() => { });
        result._promise = p;
        return result;
      };
      window.Promise = Promise2;
      window['__Promise2'] = Promise2;
    }
    """)

    # Sanity check.
    assert Page.evaluate!(page, """
           () => {
             const p = Promise.all([Promise.race([]), new Promise(() => { }).then(() => { })]);
             return p instanceof window['__Promise2'];
           }
           """) == true

    # Now, the new promise should be awaitable.
    assert Page.evaluate!(page, "() => Promise.resolve(42)") == 42
  end

  @tag skip: "not ported: assertMaxArguments (Elixir arities are fixed, extra arguments do not compile)"
  test "should throw when passed more than one parameter"

  test "should accept \"undefined\" as one of multiple parameters", %{page: page} do
    result = Page.evaluate!(page, "({ a, b }) => Object.is(a, undefined) && Object.is(b, 'foo')", %{a: nil, b: "foo"})
    assert result == true
  end

  # `toEqual({})` ignores properties that are `undefined` (`nil`).
  test "should properly serialize undefined arguments", %{page: page} do
    assert Page.evaluate!(page, "x => ({ a: x })", nil) == %{"a" => nil}
  end

  test "should properly serialize undefined fields", %{page: page} do
    assert Page.evaluate!(page, "() => ({ a: undefined })") == %{"a" => nil}
  end

  test "should return undefined properties", %{page: page} do
    value = Page.evaluate!(page, "() => ({ a: undefined })")
    assert Map.has_key?(value, "a")
  end

  test "should properly serialize null arguments", %{page: page} do
    assert Page.evaluate!(page, "x => x", :null) == :null
  end

  test "should properly serialize null fields", %{page: page} do
    assert Page.evaluate!(page, "() => ({ a: null })") == %{"a" => :null}
  end

  test "should properly serialize PerformanceMeasure object", %{page: page} do
    assert [%{"duration" => duration, "entryType" => "measure", "name" => "my-measure", "startTime" => start_time}] =
             Page.evaluate!(page, """
             () => {
               window.builtins.performance.mark('start');
               window.builtins.performance.mark('end');
               window.builtins.performance.measure('my-measure', 'start', 'end');
               return window.builtins.performance.getEntriesByType('measure');
             }
             """)

    assert is_number(duration)
    assert is_number(start_time)
  end

  test "should properly serialize window.performance object", %{page: page} do
    if !System.get_env("PW_CLOCK") do
      assert %{
               "navigation" => %{"redirectCount" => 0, "type" => type},
               "timeOrigin" => time_origin,
               "timing" => timing
             } = Page.evaluate!(page, "() => performance")

      assert is_number(type)
      assert is_number(time_origin)

      keys =
        ~w(connectEnd connectStart domComplete domContentLoadedEventEnd domContentLoadedEventStart domInteractive
           domLoading domainLookupEnd domainLookupStart fetchStart loadEventEnd loadEventStart navigationStart
           redirectEnd redirectStart requestStart responseEnd responseStart secureConnectionStart unloadEventEnd
           unloadEventStart)

      assert timing |> Map.keys() |> Enum.sort() == Enum.sort(keys)
      assert Enum.all?(Map.values(timing), &is_number/1)
    end
  end

  test "should return undefined for non-serializable objects", %{page: page} do
    assert Page.evaluate!(page, "() => function() {}") == nil
  end

  @tag skip:
         if(@browser_name == "firefox",
           do: "upstream fixme: Firefox Juggler -> Playwright serialiser does not throw for deep references."
         )
  test "should throw for too deep reference chain", %{page: page} do
    # issue: https://github.com/microsoft/playwright/issues/33997
    # it.fixme(browserName === 'firefox' && !isBidi, 'Firefox Juggler -> Playwright serialiser does not throw for deep references.')
    error =
      Page.evaluate(
        page,
        """
        depth => {
          const obj = {};
          let temp = obj;
          for (let i = 0; i < depth; i++) {
            temp[i] = {};
            temp = temp[i];
          }
          return obj;
        }
        """,
        1000
      )

    assert message(error) =~ "Cannot serialize result: object reference chain is too long."
  end

  @tag skip: if(@browser_name != "chromium", do: "upstream skip: this is a chromium-only limitation")
  test "should throw for too deep reference chain 2", %{page: page} do
    # issue: https://github.com/microsoft/playwright/issues/40940
    # it.skip(browserName !== 'chromium', 'this is a chromium-only limitation');
    error =
      Page.evaluate(
        page,
        """
        depth => {
          let node = {};
          for (let i = 0; i < depth; i++)
            node = { child: node };
          return node;
        }
        """,
        200
      )

    assert message(error) =~ "Cannot serialize result: object reference chain is too long."
  end

  # `String(fn)` is `inspect(fn)` here.
  test "should throw usable message for unserializable shallow function", %{page: page} do
    error = Page.evaluate(page, "arg => arg", fn -> nil end)
    assert message(error) =~ ~r/Attempting to serialize unexpected value: #Function</
  end

  test "should throw usable message for unserializable object one deep function", %{page: page} do
    error = Page.evaluate(page, "arg => arg", %{aProperty: fn -> nil end})
    assert message(error) =~ ~r/Attempting to serialize unexpected value at position "aProperty": #Function</
  end

  test "should throw usable message for unserializable object nested function", %{page: page} do
    error = Page.evaluate(page, "arg => arg", %{a: %{inner: %{property: fn -> nil end}}})
    assert message(error) =~ ~r/Attempting to serialize unexpected value at position "a\.inner\.property": #Function</
  end

  test "should throw usable message for unserializable array nested function", %{page: page} do
    error = Page.evaluate(page, "arg => arg", %{a: %{inner: ["firstValue", %{property: fn -> nil end}]}})

    assert message(error) =~
             ~r/Attempting to serialize unexpected value at position "a\.inner\[1\]\.property": #Function</
  end

  test "should alias Window, Document and Node", %{page: page} do
    object = Page.evaluate!(page, "[window, document, document.body]")
    assert object == ["ref: <Window>", "ref: <Document>", "ref: <Node>"]
  end

  test "should work for circular object", %{page: page} do
    result =
      Page.evaluate!(page, """
      () => {
        const a = {};
        a.b = a;
        return a;
      }
      """)

    # Elixir terms are acyclic: the back reference parses to `:circular`.
    assert result == %{"b" => :circular}
  end

  test "should be able to throw a tricky error", %{page: page} do
    window_handle = Page.evaluate_handle!(page, "() => window")

    error_text =
      case JSHandle.json_value(window_handle) do
        {:ok, value} -> value
        {:error, e} -> Exception.message(e)
      end

    error = Page.evaluate(page, "errorText => { throw new Error(errorText); }", error_text)
    assert message(error) =~ error_text
  end

  test "should accept a string", %{page: page} do
    result = Page.evaluate!(page, "1 + 2")
    assert result == 3
  end

  test "should accept a string with semi colons", %{page: page} do
    result = Page.evaluate!(page, "1 + 5;")
    assert result == 6
  end

  test "should accept a string with comments", %{page: page} do
    result = Page.evaluate!(page, "2 + 5;\n// do some math!")
    assert result == 7
  end

  test "should accept element handle as an argument", %{page: page} do
    Page.set_content!(page, "<section>42</section>")
    element = Page.query_selector!(page, "section")
    text = Page.evaluate!(page, "e => e.textContent", element)
    assert text == "42"
  end

  test "should throw if underlying element was disposed", %{page: page} do
    Page.set_content!(page, "<section>39</section>")
    element = Page.query_selector!(page, "section")
    assert element
    JSHandle.dispose!(element)
    error = Page.evaluate(page, "e => e.textContent", element)
    assert message(error) =~ "no object with guid"
  end

  test "should simulate a user gesture", %{page: page} do
    result =
      Page.evaluate!(page, """
      () => {
        document.body.appendChild(document.createTextNode('test'));
        document.execCommand('selectAll');
        return document.execCommand('copy');
      }
      """)

    assert result == true
  end

  test "should throw a nice error after a navigation", %{page: page} do
    error_promise = Task.async(fn -> Page.evaluate(page, "() => new Promise(f => window['__resolve'] = f)") end)

    Page.expect_navigation!(page, fn ->
      Page.evaluate!(page, """
      () => {
        window.location.reload();
        setTimeout(() => window['__resolve'](42), 1000);
      }
      """)
    end)

    error = Task.await(error_promise)
    assert message(error) =~ "navigation"
  end

  test "should not throw an error when evaluation does a navigation", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/one-style.html")

    result =
      Page.evaluate!(page, """
      () => {
        window.location.href = '/empty.html';
        return [42];
      }
      """)

    assert result == [42]
  end

  test "should not throw an error when evaluation does a synchronous navigation and returns an object", %{page: page} do
    # It is important to be on about:blank for sync reload.
    result =
      Page.evaluate!(page, """
      () => {
        window.location.reload();
        return { a: 42 };
      }
      """)

    assert result == %{"a" => 42}
  end

  test "should not throw an error when evaluation does a synchronous navigation and returns undefined", %{page: page} do
    # It is important to be on about:blank for sync reload.
    result =
      Page.evaluate!(page, """
      () => {
        window.location.reload();
        return undefined;
      }
      """)

    assert result == nil
  end

  @tag skip: "not ported: upstream skips it outside mode 'default' (too slow over the wire, we are a driver client)"
  test "should transfer 100Mb of data from page to node.js"

  test "should throw error with detailed information on exception inside promise ", %{page: page} do
    error =
      Page.evaluate(page, """
      () => new Promise(() => {
        throw new Error('Error in promise');
      })
      """)

    assert message(error) =~ "Error in promise"
  end

  test "should work even when JSON is set to null", %{page: page} do
    Page.evaluate!(page, "() => { window.JSON.stringify = null; window.JSON = null; }")
    result = Page.evaluate!(page, "() => ({ abc: 123 })")
    assert result == %{"abc" => 123}
  end

  test "should await promise from popup", %{page: page, server: server} do
    # Something is wrong about the way Firefox waits for the chained promise
    Page.goto!(page, server.empty_page)

    result =
      Page.evaluate!(page, """
      () => {
        const win = window.open('about:blank');
        return new win['Promise'](f => f(42));
      }
      """)

    assert result == 42
  end

  test "should work with new Function() and CSP", %{page: page, server: server} do
    TestServer.set_csp(server, "/empty.html", "script-src " <> server.prefix)
    Page.goto!(page, server.prefix <> "/empty.html")
    assert Page.evaluate!(page, "() => new Function('return true')()") == true
  end

  test "should work with non-strict expressions", %{page: page} do
    assert Page.evaluate!(page, """
           () => {
             y = 3.14;
             return y;
           }
           """) == 3.14
  end

  test "should respect use strict expression", %{page: page} do
    error =
      Page.evaluate(page, """
      () => {
        'use strict';
        variableY = 3.14;
        return variableY;
      }
      """)

    assert message(error) =~ "variableY"
  end

  test "should not leak utility script", %{page: page} do
    assert Page.evaluate!(page, "this === window") == true
  end

  test "should not leak handles", %{page: page} do
    error = Page.evaluate(page, "handles.length")
    assert message(error) =~ " handles"
  end

  test "should work with CSP", %{page: page, server: server} do
    TestServer.set_csp(server, "/empty.html", "script-src 'self'")
    Page.goto!(page, server.empty_page)
    assert Page.evaluate!(page, "() => 2 + 2") == 4
  end

  test "should evaluate exception with a function on the stack", %{page: page} do
    error =
      Page.evaluate!(page, """
      () => {
        return (function functionOnStack() {
          return new Error('error message');
        })();
      }
      """)

    assert error.message == "error message"
    assert error.stack =~ "functionOnStack"
  end

  test "should evaluate exception", %{page: page} do
    error =
      Page.evaluate!(page, """
      () => {
        function innerFunction() {
          const e = new Error('error message');
          e.name = 'foobar';
          return e;
        }
        return innerFunction();
      }
      """)

    assert is_exception(error)
    assert error.message == "error message"
    assert error.name == "foobar"
    assert error.stack =~ "innerFunction"
  end

  test "should pass exception argument", %{page: page} do
    received =
      Page.evaluate!(
        page,
        """
        e => {
          return { message: e.message, name: e.name, stack: e.stack };
        }
        """,
        inner_function()
      )

    assert received["message"] == "error message"
    assert received["name"] == "foobar"
    assert received["stack"] =~ "inner_function"
  end

  test "should evaluate date", %{page: page} do
    result = Page.evaluate!(page, "() => ({ date: new Date('2020-05-27T01:31:38.506Z') })")
    assert result == %{"date" => ~U[2020-05-27 01:31:38.506Z]}
  end

  test "should roundtrip date", %{page: page} do
    date = ~U[2020-05-27 01:31:38.506Z]
    result = Page.evaluate!(page, "date => date", date)
    assert DateTime.compare(result, date) == :eq
  end

  test "should roundtrip regex", %{page: page} do
    regex = ~r/hello/im
    result = Page.evaluate!(page, "regex => regex", regex)
    assert Regex.source(result) == Regex.source(regex)
    assert Enum.sort(Regex.opts(result)) == Enum.sort(Regex.opts(regex))
  end

  test "should jsonValue() date", %{page: page} do
    result_handle = Page.evaluate_handle!(page, "() => ({ date: new Date('2020-05-27T01:31:38.506Z') })")
    assert JSHandle.json_value!(result_handle) == %{"date" => ~U[2020-05-27 01:31:38.506Z]}
  end

  # `new URL('https://example.com')` normalizes the path to "/"; `URI.parse/1` does not.
  test "should evaluate url", %{page: page} do
    result = Page.evaluate!(page, "() => ({ url: new URL('https://example.com') })")
    assert result == %{"url" => URI.parse("https://example.com/")}
  end

  test "should roundtrip url", %{page: page} do
    url = URI.parse("https://example.com/")
    result = Page.evaluate!(page, "url => url", url)
    assert URI.to_string(result) == URI.to_string(url)
  end

  test "should jsonValue() url", %{page: page} do
    result_handle = Page.evaluate_handle!(page, "() => ({ url: new URL('https://example.com') })")
    assert JSHandle.json_value!(result_handle) == %{"url" => URI.parse("https://example.com/")}
  end

  test "should not use toJSON when evaluating", %{page: page} do
    result = Page.evaluate!(page, "() => ({ toJSON: () => 'string', data: 'data' })")
    assert result == %{"data" => "data", "toJSON" => %{}}
  end

  test "should not use Array.prototype.toJSON when evaluating", %{page: page} do
    result =
      Page.evaluate!(page, """
      () => {
        Array.prototype.toJSON = () => 'busted';
        return [1, 2, 3];
      }
      """)

    assert result == [1, 2, 3]
  end

  test "should not add a toJSON property to newly created Arrays after evaluation", %{page: page} do
    Page.evaluate!(page, "() => []")
    has_to_json_property = Page.evaluate!(page, "() => 'toJSON' in []")
    assert has_to_json_property == false
  end

  test "should not use toJSON in jsonValue", %{page: page} do
    result_handle = Page.evaluate_handle!(page, "() => ({ toJSON: () => 'string', data: 'data' })")
    assert JSHandle.json_value!(result_handle) == %{"data" => "data", "toJSON" => %{}}
  end

  test "should ignore buggy toJSON", %{page: page} do
    result =
      Page.evaluate!(page, """
      () => {
        class Foo {
          toJSON() {
            throw new Error('Bad');
          }
        }
        class Bar {
          get toJSON() {
            throw new Error('Also bad');
          }
        }
        return { foo: new Foo(), bar: new Bar() };
      }
      """)

    assert result == %{"foo" => %{}, "bar" => %{}}
  end

  test "should not expose the injected script export", %{page: page} do
    assert Page.evaluate!(page, ~s(typeof pwExport === "undefined")) == true
  end

  test "should throw when frame is detached", %{page: page, server: server} do
    attach_frame(page, "frame1", server.empty_page)
    frame = Enum.at(Page.frames(page), 1)
    promise = Task.async(fn -> Frame.evaluate(frame, "() => new Promise(() => {})") end)
    detach_frame(page, "frame1")
    error = Task.await(promise)
    assert {:error, _} = error
    assert message(error) =~ ~r/frame.evaluate: (Frame was detached|Execution context was destroyed)/
  end

  test "should work with overridden Object.defineProperty", %{page: page, server: server} do
    TestServer.set_route(server, "/test", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.send_resp(200, """
      <script>
      Object.create = null;
      Object.defineProperty = null;
      Object.getOwnPropertyDescriptor = null;
      Object.getOwnPropertyNames = null;
      Object.getPrototypeOf = null;
      Object.prototype.hasOwnProperty = null;
      </script>
      """)
    end)

    Page.goto!(page, server.prefix <> "/test")
    assert Page.evaluate!(page, "1+2") == 3
  end

  test "should work with busted Array.prototype.map/push", %{page: page, server: server} do
    TestServer.set_route(server, "/test", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.send_resp(200, """
      <script>
        Array.prototype.map = null;
        Array.prototype.push = null;
      </script>
      """)
    end)

    Page.goto!(page, server.prefix <> "/test")
    assert Page.evaluate!(page, "1+2") == 3
    assert JSHandle.json_value!(Page.evaluate_handle!(page, "1+2")) == 3
  end

  test "should work with overridden globalThis.Window/Document/Node", %{page: page, server: server} do
    test_cases = [
      "() => globalThis.Window = {}",
      "() => globalThis.Document = {}",
      "() => globalThis.Node = {}",
      "() => globalThis.Window = null",
      "() => globalThis.Document = null",
      "() => globalThis.Node = null"
    ]

    for test_case <- test_cases do
      # it.step(testCase.toString(), ...)
      Page.goto!(page, server.empty_page)
      Page.evaluate!(page, test_case)
      assert Page.evaluate!(page, "1+2") == 3, test_case
      assert Page.evaluate!(page, "() => ['foo']") == ["foo"], test_case
    end
  end

  test "should work with overridden URL/Date/RegExp", %{page: page, server: server} do
    # issue: https://github.com/microsoft/playwright/issues/21109
    test_cases = [
      "() => globalThis.URL = 'foo'",
      "() => globalThis.RegExp = 'foo'",
      "() => globalThis.Date = 'foo'"
    ]

    for test_case <- test_cases do
      # it.step(testCase.toString(), ...)
      Page.goto!(page, server.empty_page)
      Page.evaluate!(page, test_case)
      assert Page.evaluate!(page, "1+2") == 3, test_case
      assert Page.evaluate!(page, "() => ({ 'a': 2023 })") == %{"a" => 2023}, test_case
    end
  end

  test "should work with Array.from/map", %{page: page} do
    # issue: https://github.com/microsoft/playwright/issues/28520
    assert Page.evaluate!(page, """
           () => {
             const r = (str, amount) => Array.from(Array(amount)).map(() => str).join('');
             return r('([a-f0-9]{2})', 3);
           }
           """) == "([a-f0-9]{2})([a-f0-9]{2})([a-f0-9]{2})"
  end

  @tag skip: if(@browser_name == "webkit", do: "upstream skip: WebKit does not support using declarations")
  test "should work with a using declaration", %{page: page} do
    # issue: https://github.com/microsoft/playwright/issues/41511
    # it.skip(nodeVersion.major < 24, ...)  -- n/a: the page function is JS source, not lowered
    # it.skip(browserName === 'chromium' && browserMajorVersion < 134, ...)  -- we run a recent chromium
    disposed =
      Page.evaluate!(page, """
      () => {
        let disposed = false;
        {
          using r = { [Symbol.dispose]: () => { disposed = true; } };
          void r;
        }
        return disposed;
      }
      """)

    assert disposed == true
  end

  test "should ignore dangerous object keys", %{page: page} do
    input = %{"__proto__" => %{polluted: true}, "safeKey" => "safeValue"}
    result = Page.evaluate!(page, "arg => arg", input)
    assert result == %{"safeKey" => "safeValue"}
  end
end
