defmodule PlaywrightEx.Library.PageClockTest do
  @upstream "tests/library/page-clock.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Clock
  alias PlaywrightEx.ConsoleMessage
  alias PlaywrightEx.JSHandle
  alias PlaywrightEx.Page
  alias PlaywrightEx.TestServer

  @moduletag :page

  # test.skip(!!process.env.PW_CLOCK);  -- not ported: no frozen-clock mode

  # The `calls` fixture (`test.extend`) records `window.stub` calls through `page.exposeFunction`:
  # a `:calls` tag asks for it, `calls.()` returns the calls so far. Elixir functions have a fixed
  # arity: `stub` takes the one `param` of its declared type (`stub()` records `params: [nil]`).
  setup %{page: page} = tags do
    if tags[:calls] do
      # Not linked or stopped: a late `stub` call must not hit a dead process.
      {:ok, calls} = Agent.start(fn -> [] end)
      Page.expose_function!(page, "stub", fn param -> Agent.update(calls, &(&1 ++ [%{params: [param]}])) end)
      %{calls: fn -> Agent.get(calls, & &1) end}
    else
      :ok
    end
  end

  defp pause_at_1000(%{page: page}) do
    Clock.install!(Page.clock(page), time: 0)
    Clock.pause_at!(Page.clock(page), 1000)
    :ok
  end

  describe "runFor" do
    setup :pause_at_1000

    @tag :calls
    test "triggers immediately without specified delay", %{page: page, calls: calls} do
      Page.evaluate!(page, """
      async () => {
        setTimeout(window.stub);
      }
      """)

      Clock.run_for!(Page.clock(page), 0)
      assert length(calls.()) == 1
    end

    @tag :calls
    test "does not trigger without sufficient delay", %{page: page, calls: calls} do
      Page.evaluate!(page, """
      async () => {
        setTimeout(window.stub, 100);
      }
      """)

      Clock.run_for!(Page.clock(page), 10)
      assert calls.() == []
    end

    @tag :calls
    test "triggers after sufficient delay", %{page: page, calls: calls} do
      Page.evaluate!(page, """
      async () => {
        setTimeout(window.stub, 100);
      }
      """)

      Clock.run_for!(Page.clock(page), 100)
      assert length(calls.()) == 1
    end

    @tag :calls
    test "triggers simultaneous timers", %{page: page, calls: calls} do
      Page.evaluate!(page, """
      async () => {
        setTimeout(window.stub, 100);
        setTimeout(window.stub, 100);
      }
      """)

      Clock.run_for!(Page.clock(page), 100)
      assert length(calls.()) == 2
    end

    @tag :calls
    test "triggers multiple simultaneous timers", %{page: page, calls: calls} do
      Page.evaluate!(page, """
      async () => {
        setTimeout(window.stub, 100);
        setTimeout(window.stub, 100);
        setTimeout(window.stub, 99);
        setTimeout(window.stub, 100);
      }
      """)

      Clock.run_for!(Page.clock(page), 100)
      assert length(calls.()) == 4
    end

    @tag :calls
    test "waits after setTimeout was called", %{page: page, calls: calls} do
      Page.evaluate!(page, """
      async () => {
        setTimeout(window.stub, 150);
      }
      """)

      Clock.run_for!(Page.clock(page), 50)
      assert calls.() == []
      Clock.run_for!(Page.clock(page), 100)
      assert length(calls.()) == 1
    end

    @tag :calls
    test "triggers event when some throw", %{page: page, calls: calls} do
      Page.evaluate!(page, """
      async () => {
        setTimeout(() => { throw new Error(); }, 100);
        setTimeout(window.stub, 120);
      }
      """)

      {:error, _} = Clock.run_for(Page.clock(page), 120)
      assert length(calls.()) == 1
    end

    @tag :calls
    test "creates updated Date while ticking", %{page: page, calls: calls} do
      Clock.set_system_time!(Page.clock(page), 0)

      Page.evaluate!(page, """
      async () => {
        setInterval(() => {
          window.stub(new Date().getTime());
        }, 10);
      }
      """)

      Clock.run_for!(Page.clock(page), 100)
      assert calls.() == for(t <- 10..100//10, do: %{params: [t]})
    end

    @tag :calls
    test "passes 8 seconds", %{page: page, calls: calls} do
      Page.evaluate!(page, """
      async () => {
        setInterval(window.stub, 4000);
      }
      """)

      Clock.run_for!(Page.clock(page), "08")
      assert length(calls.()) == 2
    end

    @tag :calls
    test "passes 1 minute", %{page: page, calls: calls} do
      Page.evaluate!(page, """
      async () => {
        setInterval(window.stub, 6000);
      }
      """)

      Clock.run_for!(Page.clock(page), "01:00")
      assert length(calls.()) == 10
    end

    @tag :calls
    test "passes 2 hours, 34 minutes and 10 seconds", %{page: page, calls: calls} do
      Page.evaluate!(page, """
      async () => {
        setInterval(window.stub, 10000);
      }
      """)

      Clock.run_for!(Page.clock(page), "02:34:10")
      assert length(calls.()) == 925
    end

    @tag :calls
    test "throws for invalid format", %{page: page, calls: calls} do
      Page.evaluate!(page, """
      async () => {
        setInterval(window.stub, 10000);
      }
      """)

      {:error, _} = Clock.run_for(Page.clock(page), "12:02:34:10")
      assert calls.() == []
    end

    test "returns the current now value", %{page: page} do
      Clock.set_system_time!(Page.clock(page), 0)
      value = 200
      Clock.run_for!(Page.clock(page), value)
      assert Page.evaluate!(page, "() => Date.now()") == value
    end
  end

  describe "fastForward" do
    setup :pause_at_1000

    @tag :calls
    test "ignores timers which wouldn't be run", %{page: page, calls: calls} do
      Page.evaluate!(page, """
      async () => {
        setTimeout(() => {
          window.stub('should not be logged');
        }, 1000);
      }
      """)

      Clock.fast_forward!(Page.clock(page), 500)
      assert calls.() == []
    end

    @tag :calls
    test "pushes back execution time for skipped timers", %{page: page, calls: calls} do
      Page.evaluate!(page, """
      async () => {
        setTimeout(() => {
          window.stub(Date.now());
        }, 1000);
      }
      """)

      Clock.fast_forward!(Page.clock(page), 2000)
      assert calls.() == [%{params: [1000 + 2000]}]
    end

    @tag :calls
    test "supports string time arguments", %{page: page, calls: calls} do
      Page.evaluate!(page, """
      async () => {
        setTimeout(() => {
          window.stub(Date.now());
        }, 100000);  // 100000 = 1:40
      }
      """)

      Clock.fast_forward!(Page.clock(page), "01:50")
      assert calls.() == [%{params: [1000 + 110_000]}]
    end
  end

  describe "stubTimers" do
    setup :pause_at_1000

    @tag :calls
    test "sets initial timestamp", %{page: page} do
      Clock.set_system_time!(Page.clock(page), 1400)
      assert Page.evaluate!(page, "() => Date.now()") == 1400
    end

    test "should throw for invalid date", %{page: page} do
      # setSystemTime(new Date('invalid')) rejects with 'Invalid date: Invalid Date'  -- not ported: a DateTime is always valid
      {:error, error} = Clock.set_system_time(Page.clock(page), "invalid")
      assert Exception.message(error) =~ "clock.setSystemTime: Invalid date: invalid"
    end

    @tag :calls
    test "replaces global setTimeout", %{page: page, calls: calls} do
      Page.evaluate!(page, """
      async () => {
        setTimeout(window.stub, 1000);
      }
      """)

      Clock.run_for!(Page.clock(page), 1000)
      assert length(calls.()) == 1
    end

    @tag :calls
    test "global fake setTimeout should return id", %{page: page} do
      to = Page.evaluate!(page, "() => setTimeout(window.stub, 1000)")
      assert is_number(to)
    end

    @tag :calls
    test "replaces global clearTimeout", %{page: page, calls: calls} do
      Page.evaluate!(page, """
      async () => {
        const to = setTimeout(window.stub, 1000);
        clearTimeout(to);
      }
      """)

      Clock.run_for!(Page.clock(page), 1000)
      assert calls.() == []
    end

    @tag :calls
    test "replaces global setInterval", %{page: page, calls: calls} do
      Page.evaluate!(page, """
      async () => {
        setInterval(window.stub, 500);
      }
      """)

      Clock.run_for!(Page.clock(page), 1000)
      assert length(calls.()) == 2
    end

    @tag :calls
    test "replaces global clearInterval", %{page: page, calls: calls} do
      Page.evaluate!(page, """
      async () => {
        const to = setInterval(window.stub, 500);
        clearInterval(to);
      }
      """)

      Clock.run_for!(Page.clock(page), 1000)
      assert calls.() == []
    end

    test "replaces global performance.now", %{page: page} do
      promise =
        Task.async(fn ->
          Page.evaluate!(page, """
          async () => {
            const prev = performance.now();
            await new Promise(f => setTimeout(f, 1000));
            const next = performance.now();
            return { prev, next };
          }
          """)
        end)

      # JS starts the evaluate before runFor; let the task send it first.
      Process.sleep(100)
      Clock.run_for!(Page.clock(page), 1000)
      assert Task.await(promise) == %{"prev" => 1000, "next" => 2000}
    end

    test "fakes Date constructor", %{page: page} do
      now = Page.evaluate!(page, "() => new Date().getTime()")
      assert now == 1000
    end
  end

  # describe "stubTimers" (a second block upstream; ExUnit describe names are unique)

  test "replaces global performance.timeOrigin", %{page: page} do
    Clock.install!(Page.clock(page), time: 1000)
    Clock.pause_at!(Page.clock(page), 2000)

    promise =
      Task.async(fn ->
        Page.evaluate!(page, """
        async () => {
          const prev = performance.now();
          await new Promise(f => setTimeout(f, 1000));
          const next = performance.now();
          return { prev, next };
        }
        """)
      end)

    # JS starts the evaluate before runFor; let the task send it first.
    Process.sleep(100)
    Clock.run_for!(Page.clock(page), 1000)
    assert Page.evaluate!(page, "() => performance.timeOrigin") == 1000
    assert Task.await(promise) == %{"prev" => 1000, "next" => 2000}
  end

  describe "popup" do
    test "should tick after popup", %{page: page} do
      Clock.install!(Page.clock(page), time: 0)
      now = ~U[2015-09-25 00:00:00Z]
      Clock.pause_at!(Page.clock(page), now)
      popup = Page.expect_popup!(page, fn -> Page.evaluate!(page, "() => window.open('about:blank')") end)
      popup_time = Page.evaluate!(popup, "() => Date.now()")
      assert popup_time == DateTime.to_unix(now, :millisecond)
      Clock.run_for!(Page.clock(page), 1000)
      popup_time_after = Page.evaluate!(popup, "() => Date.now()")
      assert popup_time_after == DateTime.to_unix(now, :millisecond) + 1000
    end

    test "should tick before popup", %{page: page} do
      Clock.install!(Page.clock(page), time: 0)
      now = ~U[2015-09-25 00:00:00Z]
      Clock.pause_at!(Page.clock(page), now)
      Clock.run_for!(Page.clock(page), 1000)

      popup = Page.expect_popup!(page, fn -> Page.evaluate!(page, "() => window.open('about:blank')") end)
      popup_time = Page.evaluate!(popup, "() => Date.now()")
      assert popup_time == DateTime.to_unix(now, :millisecond) + 1000
    end

    test "should run time before popup", %{page: page, server: server} do
      TestServer.set_route(server, "/popup.html", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/html")
        |> Plug.Conn.send_resp(200, "<script>window.time = Date.now()</script>")
      end)

      Page.goto!(page, server.empty_page)
      # Wait for 2 second in real life to check that it is past in popup.
      Page.wait_for_timeout!(page, 2000)

      popup =
        Page.expect_popup!(page, fn ->
          Page.evaluate!(page, "url => window.open(url)", server.prefix <> "/popup.html")
        end)

      popup_time = Page.evaluate!(popup, "time")
      assert popup_time >= 2000
    end

    test "should not run time before popup on pause", %{page: page, server: server} do
      TestServer.set_route(server, "/popup.html", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/html")
        |> Plug.Conn.send_resp(200, "<script>window.time = Date.now()</script>")
      end)

      Clock.install!(Page.clock(page), time: 0)
      Clock.pause_at!(Page.clock(page), 1000)
      Page.goto!(page, server.empty_page)
      # Wait for 2 second in real life to check that it is past in popup.
      Page.wait_for_timeout!(page, 2000)

      popup =
        Page.expect_popup!(page, fn ->
          Page.evaluate!(page, "url => window.open(url)", server.prefix <> "/popup.html")
        end)

      Page.wait_for_load_state!(popup)
      popup_time = Page.evaluate!(popup, "time")
      assert popup_time == 1000
    end
  end

  describe "setFixedTime" do
    test "does not fake methods", %{page: page} do
      Clock.set_fixed_time!(Page.clock(page), 0)

      # Should not stall.
      Page.evaluate!(page, """
      () => {
        return new Promise(f => setTimeout(f, 1));
      }
      """)
    end

    test "allows setting time multiple times", %{page: page} do
      Clock.set_fixed_time!(Page.clock(page), 100)
      assert Page.evaluate!(page, "() => Date.now()") == 100
      Clock.set_fixed_time!(Page.clock(page), 200)
      assert Page.evaluate!(page, "() => Date.now()") == 200
    end

    test "fixed time is not affected by clock manipulation", %{page: page} do
      Clock.set_fixed_time!(Page.clock(page), 100)
      assert Page.evaluate!(page, "() => Date.now()") == 100
      Clock.fast_forward!(Page.clock(page), 20)
      assert Page.evaluate!(page, "() => Date.now()") == 100
    end

    @tag :calls
    test "allows installing fake timers after settings time", %{page: page, calls: calls} do
      Clock.set_fixed_time!(Page.clock(page), 100)
      assert Page.evaluate!(page, "() => Date.now()") == 100
      Clock.set_fixed_time!(Page.clock(page), 200)

      Page.evaluate!(page, """
      async () => {
        setTimeout(() => window.stub(Date.now()));
      }
      """)

      Clock.run_for!(Page.clock(page), 0)
      assert calls.() == [%{params: [200]}]
    end
  end

  describe "while running" do
    test "should progress time", %{page: page} do
      Clock.install!(Page.clock(page), time: 0)
      start_real_time = System.system_time(:millisecond)
      Page.goto!(page, "data:text/html,")
      Page.wait_for_timeout!(page, 1000)
      now = Page.evaluate!(page, "() => Date.now()")
      real_elapsed = System.system_time(:millisecond) - start_real_time
      assert now >= 1000
      assert now <= real_elapsed + 1000
    end

    test "should runFor", %{page: page} do
      Clock.install!(Page.clock(page), time: 0)
      start_real_time = System.system_time(:millisecond)
      Page.goto!(page, "data:text/html,")
      Clock.run_for!(Page.clock(page), 10_000)
      now = Page.evaluate!(page, "() => Date.now()")
      real_elapsed = System.system_time(:millisecond) - start_real_time
      assert now >= 10_000
      assert now <= 10_000 + real_elapsed + 1000
    end

    test "should fastForward", %{page: page} do
      Clock.install!(Page.clock(page), time: 0)
      start_real_time = System.system_time(:millisecond)
      Page.goto!(page, "data:text/html,")
      Clock.fast_forward!(Page.clock(page), 10_000)
      now = Page.evaluate!(page, "() => Date.now()")
      real_elapsed = System.system_time(:millisecond) - start_real_time
      assert now >= 10_000
      assert now <= 10_000 + real_elapsed + 1000
    end

    test "should pause", %{page: page} do
      Clock.install!(Page.clock(page), time: 0)
      Page.goto!(page, "data:text/html,")
      Clock.pause_at!(Page.clock(page), 60_000)
      # Internally wait to make sure the clock is paused and not running.
      Page.wait_for_timeout!(page, 1111)
      now = Page.evaluate!(page, "() => Date.now()")
      assert now == 60_000
    end

    test "should reject an invalid target time with an active requestAnimationFrame loop", %{page: page} do
      Clock.install!(Page.clock(page))

      Page.set_content!(
        page,
        "<script>function tick() { requestAnimationFrame(tick); } requestAnimationFrame(tick);</script>"
      )

      # The JS number and its JS string form (an Elixir integer would print more digits than the double).
      [invalid_time, invalid_time_string] =
        Page.evaluate!(page, "() => { const t = Date.now() * 1_000_000; return [t, String(t)]; }")

      {:error, error} = Clock.pause_at(Page.clock(page), invalid_time)
      assert Exception.message(error) =~ "clock.pauseAt: Invalid date: #{invalid_time_string}"
    end

    test "should pause and fastForward", %{page: page} do
      Clock.install!(Page.clock(page), time: 0)
      Page.goto!(page, "data:text/html,")
      Clock.pause_at!(Page.clock(page), 60_000)
      Clock.fast_forward!(Page.clock(page), 1000)
      now = Page.evaluate!(page, "() => Date.now()")
      assert now == 61_000
    end

    test "should set system time on pause", %{page: page} do
      Clock.install!(Page.clock(page), time: 0)
      Page.goto!(page, "data:text/html,")
      Clock.pause_at!(Page.clock(page), 60_000)
      now = Page.evaluate!(page, "() => Date.now()")
      assert now == 60_000
    end
  end

  describe "while on pause" do
    @tag :calls
    test "fastForward should not run nested immediate", %{page: page, calls: calls} do
      Clock.install!(Page.clock(page), time: 0)
      Page.goto!(page, "data:text/html,")
      Clock.pause_at!(Page.clock(page), 1000)

      Page.evaluate!(page, """
      () => {
        setTimeout(() => {
          window.stub('outer');
          setTimeout(() => window.stub('inner'), 0);
        }, 1000);
      }
      """)

      Clock.fast_forward!(Page.clock(page), 1000)
      assert calls.() == [%{params: ["outer"]}]
      Clock.fast_forward!(Page.clock(page), 1)
      assert calls.() == [%{params: ["outer"]}, %{params: ["inner"]}]
    end

    @tag :calls
    test "runFor should not run nested immediate", %{page: page, calls: calls} do
      Clock.install!(Page.clock(page), time: 0)
      Page.goto!(page, "data:text/html,")
      Clock.pause_at!(Page.clock(page), 1000)

      Page.evaluate!(page, """
      () => {
        setTimeout(() => {
          window.stub('outer');
          setTimeout(() => window.stub('inner'), 0);
        }, 1000);
      }
      """)

      Clock.run_for!(Page.clock(page), 1000)
      assert calls.() == [%{params: ["outer"]}]
      Clock.run_for!(Page.clock(page), 1)
      assert calls.() == [%{params: ["outer"]}, %{params: ["inner"]}]
    end

    @tag :calls
    test "runFor should not run nested immediate from microtask", %{page: page, calls: calls} do
      Clock.install!(Page.clock(page), time: 0)
      Page.goto!(page, "data:text/html,")
      Clock.pause_at!(Page.clock(page), 1000)

      Page.evaluate!(page, """
      () => {
        setTimeout(() => {
          window.stub('outer');
          void Promise.resolve().then(() => setTimeout(() => window.stub('inner'), 0));
        }, 1000);
      }
      """)

      Clock.run_for!(Page.clock(page), 1000)
      assert calls.() == [%{params: ["outer"]}]
      Clock.run_for!(Page.clock(page), 1)
      assert calls.() == [%{params: ["outer"]}, %{params: ["inner"]}]
    end
  end

  describe "Date.now" do
    test "check Date.now is an integer", %{page: page} do
      Clock.install!(Page.clock(page))
      Page.goto!(page, "data:text/html,")
      Page.wait_for_timeout!(page, 1000)
      date_value = Page.evaluate!(page, "Date.now()")
      assert is_integer(date_value)
      Page.wait_for_timeout!(page, 1000)
      date_value2 = Page.evaluate!(page, "Date.now()")
      assert is_integer(date_value2)
    end

    test "check Date.now is an integer (2)", %{page: page} do
      Clock.install!(Page.clock(page), time: 0)
      Page.goto!(page, "data:text/html,")
      Clock.pause_at!(Page.clock(page), 1000)
      Clock.run_for!(Page.clock(page), 0.5)
      date_value = Page.evaluate!(page, "Date.now()")
      assert date_value == 1001
    end
  end

  describe "Temporal.Now" do
    # it.beforeEach: it.skip(!await page.evaluate(() => 'Temporal' in globalThis), 'Temporal is not supported');
    # ExUnit cannot skip at runtime: each test returns early instead.
    defp temporal?(page), do: Page.evaluate!(page, "() => 'Temporal' in globalThis")

    test "should follow fixed time", %{page: page} do
      if temporal?(page) do
        Clock.set_fixed_time!(Page.clock(page), ~U[2020-01-01 00:00:00Z])
        Page.goto!(page, "data:text/html,")

        assert Page.evaluate!(page, """
               () => {
                 const Temporal = globalThis.Temporal;
                 return {
                   instant: Temporal.Now.instant().toString(),
                   zonedDateTime: Temporal.Now.zonedDateTimeISO('UTC').toString(),
                   plainDateTime: Temporal.Now.plainDateTimeISO('UTC').toString(),
                   plainDate: Temporal.Now.plainDateISO('UTC').toString(),
                   plainTime: Temporal.Now.plainTimeISO('UTC').toString(),
                 };
               }
               """) == %{
                 "instant" => "2020-01-01T00:00:00Z",
                 "zonedDateTime" => "2020-01-01T00:00:00+00:00[UTC]",
                 "plainDateTime" => "2020-01-01T00:00:00",
                 "plainDate" => "2020-01-01",
                 "plainTime" => "00:00:00"
               }
      end
    end

    test "should advance with the clock", %{page: page} do
      if temporal?(page) do
        Clock.install!(Page.clock(page), time: 0)
        Page.goto!(page, "data:text/html,")
        Clock.pause_at!(Page.clock(page), 1000)
        Clock.run_for!(Page.clock(page), 2000)
        assert Page.evaluate!(page, "() => globalThis.Temporal.Now.instant().epochMilliseconds") == 3000
      end
    end

    test "should use the system time zone by default", %{page: page, browser: browser} do
      if temporal?(page) do
        context = Browser.new_context!(browser, timezone_id: "America/Los_Angeles")
        page = BrowserContext.new_page!(context)
        Clock.set_fixed_time!(Page.clock(page), ~U[2020-01-01 00:00:00Z])
        Page.goto!(page, "data:text/html,")

        assert Page.evaluate!(page, """
               () => {
                 const Temporal = globalThis.Temporal;
                 return {
                   timeZoneId: Temporal.Now.timeZoneId(),
                   zonedDateTime: Temporal.Now.zonedDateTimeISO().toString(),
                   plainDateTime: Temporal.Now.plainDateTimeISO().toString(),
                 };
               }
               """) == %{
                 "timeZoneId" => "America/Los_Angeles",
                 "zonedDateTime" => "2019-12-31T16:00:00-08:00[America/Los_Angeles]",
                 "plainDateTime" => "2019-12-31T16:00:00"
               }

        BrowserContext.close!(context)
      end
    end

    test "should keep the rest of Temporal intact", %{page: page} do
      if temporal?(page) do
        Clock.install!(Page.clock(page), time: 0)
        Page.goto!(page, "data:text/html,")

        assert Page.evaluate!(page, """
               () => {
                 const Temporal = globalThis.Temporal;
                 return {
                   tag: Object.prototype.toString.call(Temporal.Now),
                   enumerable: Object.keys(Temporal).concat(Object.keys(Temporal.Now)),
                   isInstant: Temporal.Now.instant() instanceof Temporal.Instant,
                   duration: Temporal.Duration.from({ hours: 1 }).toString(),
                 };
               }
               """) == %{
                 "tag" => "[object Temporal.Now]",
                 "enumerable" => [],
                 "isInstant" => true,
                 "duration" => "PT1H"
               }
      end
    end
  end

  test "AbortSignal.timeout", %{page: page, browser_name: browser_name} do
    Clock.install!(Page.clock(page), time: 0)

    controller =
      Page.evaluate_handle!(page, """
      () => {
        const signal = AbortSignal.any([
          AbortSignal.timeout(100)
        ]);
        const handle = {
          signal,
          event: false,
          handler: false,
        };
        signal.addEventListener('abort', () => handle.event = true);
        signal.onabort = () => handle.handler = true;
        return handle;
      }
      """)

    assert JSHandle.evaluate!(controller, """
           handle => ({
             signal: handle.signal.aborted,
             event: handle.event,
             handler: handle.handler,
           })
           """) == %{"signal" => false, "event" => false, "handler" => false}

    Clock.run_for!(Page.clock(page), 200)

    assert JSHandle.evaluate!(controller, """
           handle => ({
             signal: handle.signal.aborted,
             event: handle.event,
             handler: handle.handler,
             reason: {
               name: handle.signal.reason.name,
               message: handle.signal.reason.message,
               code: handle.signal.reason.code,
             },
           })
           """) == %{
             "signal" => true,
             "event" => true,
             "handler" => true,
             "reason" => %{
               "name" => "TimeoutError",
               "message" => if(browser_name == "chromium", do: "signal timed out", else: "The operation timed out."),
               "code" => 23
             }
           }

    assert Page.evaluate!(page, "() => AbortSignal.abort().aborted") == true
  end

  test "correctly increments Date.now()/performance.now() during blocking execution", %{page: page, server: server} do
    Clock.set_system_time!(Page.clock(page), ~U[2026-01-01 00:00:00Z])

    TestServer.set_route(server, "/repro.html", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.send_resp(200, """
        <html>
          <body>
            <script>
            {
              const start = performance.now();
              while (performance.now() - start < 100) { }
            }
            {
              const start = Date.now();
              while (Date.now() - start < 100) { }
            }
            console.log('done');
            </script>
          </body>
        </html>
      """)
    end)

    wait_for_done = Page.wait_for_event(page, :console, predicate: &(ConsoleMessage.text(&1) == "done"))
    Page.goto!(page, server.prefix <> "/repro.html")
    PlaywrightEx.Promise.await!(wait_for_done)
  end
end
