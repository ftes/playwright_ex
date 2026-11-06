defmodule PlaywrightEx.Library.HitTargetTest do
  @upstream "tests/library/hit-target.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.ElementHandle
  alias PlaywrightEx.Expect
  alias PlaywrightEx.Frame
  alias PlaywrightEx.FrameLocator
  alias PlaywrightEx.JSHandle
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page

  @moduletag :page

  test "should block all events when hit target is wrong", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/button.html")

    Page.evaluate!(page, """
    () => {
      const blocker = document.createElement('div');
      blocker.style.position = 'absolute';
      blocker.style.width = '400px';
      blocker.style.height = '400px';
      blocker.style.left = '0';
      blocker.style.top = '0';
      document.body.appendChild(blocker);

      const allEvents = [];
      window.allEvents = allEvents;
      for (const name of ['mousedown', 'mouseup', 'click', 'dblclick', 'auxclick', 'contextmenu', 'pointerdown', 'pointerup']) {
        window.addEventListener(name, e => allEvents.push(e.type));
        blocker.addEventListener(name, e => allEvents.push(e.type));
      }
    }
    """)

    {:error, error} = Page.click(page, "button", timeout: 3000)
    assert Exception.message(error) =~ "page.click: Timeout 3000ms exceeded."

    # Give it some time, just in case.
    Page.wait_for_timeout!(page, 1000)
    all_events = Page.evaluate!(page, "() => window.allEvents")
    assert all_events == []
  end

  test "should block click when mousedown fails", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/button.html")

    Page.eval_on_selector!(page, "button", """
    button => {
      button.addEventListener('mousemove', () => {
        button.style.marginLeft = '100px';
      });

      const allEvents = [];
      window.allEvents = allEvents;
      for (const name of ['mousemove', 'mousedown', 'mouseup', 'click', 'dblclick', 'auxclick', 'contextmenu', 'pointerdown', 'pointerup'])
        button.addEventListener(name, e => allEvents.push(e.type));
    }
    """)

    Page.click!(page, "button")
    assert Page.evaluate!(page, "result") == "Clicked"
    all_events = Page.evaluate!(page, "() => window.allEvents")

    assert all_events == [
             # First attempt failed.
             "mousemove",
             # Second attempt succeeded.
             "mousemove",
             "pointerdown",
             "mousedown",
             "pointerup",
             "mouseup",
             "click"
           ]
  end

  test "should click when element detaches in mousedown", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/button.html")

    Page.eval_on_selector!(page, "button", """
    button => {
      button.addEventListener('mousedown', () => {
        window.result = 'Mousedown';
        button.remove();
      });
    }
    """)

    Page.click!(page, "button", timeout: 15_000)
    assert Page.evaluate!(page, "result") == "Mousedown"
  end

  test "should block all events when hit target is wrong and element detaches", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/button.html")

    Page.eval_on_selector!(page, "button", """
    button => {
      const blocker = document.createElement('div');
      blocker.style.position = 'absolute';
      blocker.style.width = '400px';
      blocker.style.height = '400px';
      blocker.style.left = '0';
      blocker.style.top = '0';
      document.body.appendChild(blocker);

      window.addEventListener('mousemove', () => button.remove());

      const allEvents = [];
      window.allEvents = allEvents;
      for (const name of ['mousedown', 'mouseup', 'click', 'dblclick', 'auxclick', 'contextmenu', 'pointerdown', 'pointerup']) {
        window.addEventListener(name, e => allEvents.push(e.type));
        blocker.addEventListener(name, e => allEvents.push(e.type));
      }
    }
    """)

    {:error, error} = Page.click(page, "button", timeout: 3000)
    assert Exception.message(error) =~ "page.click: Timeout 3000ms exceeded."

    # Give it some time, just in case.
    Page.wait_for_timeout!(page, 1000)
    all_events = Page.evaluate!(page, "() => window.allEvents")
    assert all_events == []
  end

  test "should not block programmatic events", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/button.html")

    Page.eval_on_selector!(page, "button", """
    button => {
      button.addEventListener('mousemove', () => {
        button.style.marginLeft = '100px';
        button.dispatchEvent(new MouseEvent('click'));
      });

      const allEvents = [];
      window.allEvents = allEvents;
      button.addEventListener('click', e => {
        if (!e.isTrusted)
          allEvents.push(e.type);
      });
    }
    """)

    Page.click!(page, "button")
    assert Page.evaluate!(page, "result") == "Clicked"
    all_events = Page.evaluate!(page, "() => window.allEvents")
    # We should get one programmatic click on each attempt.
    assert all_events == ["click", "click"]
  end

  test "should click the button again after document.write", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/button.html")
    Page.click!(page, "button")
    assert Page.evaluate!(page, "result") == "Clicked"

    Page.evaluate!(page, """
    () => {
      document.open();
      document.write('<button onclick="window.result2 = true"></button>');
      document.close();
    }
    """)

    Page.click!(page, "button")
    assert Page.evaluate!(page, "result2") == true
  end

  test "should work with mui select", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/mui.html")

    Page.evaluate!(page, """
    () => {
      renderComponent(e(MaterialUI.FormControl, { fullWidth: true }, [
        e(MaterialUI.InputLabel, { id: 'demo-simple-select-label' }, ['Age']),
        e(MaterialUI.Select, {
          labelId: 'demo-simple-select-label',
          id: 'demo-simple-select',
          value: 10,
          label: 'Age',
        }, [
          e(MaterialUI.MenuItem, { value: 10 }, ['Ten']),
          e(MaterialUI.MenuItem, { value: 20 }, ['Twenty']),
          e(MaterialUI.MenuItem, { value: 30 }, ['Thirty']),
        ]),
      ]));
    }
    """)

    Page.click!(page, ~s[div.MuiFormControl-root:has-text("Age")])
    Expect.to_be_visible!(Page.locator(page, "text=Thirty"))
  end

  test "should work with drag and drop that moves the element under cursor", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/drag-n-drop-manual.html")
    Page.drag_and_drop!(page, "#from", "#to")
    Expect.to_have_text!(Page.locator(page, "#to"), "Dropped")
  end

  test "should work with block inside inline", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    Page.set_content!(page, """
      <div>
        <span>
          <div id="target" onclick="window._clicked=true">
            Romimine
          </div>
        </span>
      </div>
    """)

    Locator.click!(Page.locator(page, "#target"))
    assert Page.evaluate!(page, "window._clicked") == true
  end

  test "should work with block-block-block inside inline-inline", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    Page.set_content!(page, """
      <div>
        <a href="#ney">
          <div>
            <span>
              <a href="#yay">
                <div>
                  <h3 id="target">
                    Romimine
                  </h3>
                </div>
              </a>
            </span>
          </div>
        </a>
      </div>
    """)

    Locator.click!(Page.locator(page, "#target"))
    Expect.to_have_url!(page, server.empty_page <> "#yay")
  end

  test "should work with block inside inline in shadow dom", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    Page.set_content!(page, """
      <div>
      </div>
      <script>
        const root = document.querySelector('div');
        const shadowRoot = root.attachShadow({ mode: 'open' });
        const span = document.createElement('span');
        shadowRoot.appendChild(span);
        const div = document.createElement('div');
        span.appendChild(div);
        div.id = 'target';
        div.addEventListener('click', () => window._clicked = true);
        div.textContent = 'Hello';
      </script>
    """)

    Locator.click!(Page.locator(page, "#target"))
    assert Page.evaluate!(page, "window._clicked") == true
  end

  test "should not click iframe overlaying the target", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    Page.set_content!(page, """
      <button style="position: absolute; left: 250px;bottom: 0;height: 40px;width: 200px;" onclick="window._clicked=1">
        click-me
      </button>
      <div style="background: transparent; bottom: 0px; left: 0px; margin: 0px; padding: 0px; position: fixed; z-index: 2147483647;">
        <iframe srcdoc="<body onclick='window.top._clicked=2' style='background-color:red;height:40px;'></body>" style="display: block; border: 0px; width: 100vw; height: 48px;"></iframe>
      </div>
    """)

    {:error, error} = Page.click(page, "text=click-me", timeout: 3000)
    assert Page.evaluate!(page, "window._clicked") == nil

    assert Exception.message(error) =~
             ~s[<iframe srcdoc="<body onclick='window.top._clicked=2' style='background-color:red;height:40px;'></body>"></iframe> from <div>…</div> subtree intercepts pointer events]
  end

  test "should not click an element overlaying iframe with the target", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    Page.set_content!(page, """
      <div onclick='window.top._clicked=1'>padding</div>
      <iframe width=600 height=600 srcdoc="<iframe srcdoc='<div onclick=&quot;window.top._clicked=2&quot;>padding</div><div onclick=&quot;window.top._clicked=3&quot;>inner</div>'></iframe><div onclick='window.top._clicked=4'>outer</div>"></iframe>
      <div onclick='window.top._clicked=5' style="position: absolute; left: 0; right: 0; top: 0; bottom: 0; background: rgba(255, 0, 0, 0.1); padding: 200px;">PINK OVERLAY</div>
    """)

    target =
      page
      |> Page.frame_locator("iframe")
      |> FrameLocator.frame_locator("iframe")
      |> FrameLocator.locator("text=inner")

    {:error, error} = Locator.click(target, timeout: 3000)
    assert Page.evaluate!(page, "window._clicked") == nil

    assert Exception.message(error) =~
             ~s[<div onclick="window.top._clicked=5">PINK OVERLAY</div> intercepts pointer events]

    Locator.evaluate!(Page.locator(page, "text=overlay"), "e => e.style.display = 'none'")

    Locator.click!(target)
    assert Page.evaluate!(page, "window._clicked") == 3
  end

  test "should click into frame inside closed shadow root", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    Page.set_content!(page, """
      <div id=framecontainer>
      </div>
      <script>
        const iframe = document.createElement('iframe');
        iframe.setAttribute('name', 'myframe');
        iframe.setAttribute('srcdoc', '<div onclick="window.top.__clicked = true">click me</div>');
        const div = document.getElementById('framecontainer');
        const host = div.attachShadow({ mode: 'closed' });
        host.appendChild(iframe);
      </script>
    """)

    frame = Enum.at(Page.frames(page), 1)
    Locator.click!(Frame.locator(frame, "text=click me"))
    assert Page.evaluate!(page, "window.__clicked") == true
  end

  test "should click an element inside closed shadow root", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    Page.set_content!(page, """
      <div id=container>
      </div>
      <script>
        const span = document.createElement('span');
        span.textContent = 'click me';
        span.addEventListener('click', () => window.__clicked = true);
        const div = document.getElementById('container');
        const host = div.attachShadow({ mode: 'closed' });
        host.appendChild(span);
        window.__target = span;
      </script>
    """)

    handle = Page.evaluate_handle!(page, "window.__target")
    ElementHandle.click!(JSHandle.as_element(handle))
    assert Page.evaluate!(page, "window.__clicked") == true
  end

  test "should detect overlay from another shadow root", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    Page.set_content!(page, """
      <style>
        div > div {
          position: absolute;
          top: 0;
          left: 0;
          width: 10px;
          height: 10px;
        }
        span {
          display: block;
          position: absolute;
          left: 0;
          top: 0;
          width: 300px;
          height: 300px;
        }
      </style>
      <div style="position:relative; width:300px; height:300px">
        <div id=container1></div>
        <div id=container2></div>
      </div>
      <script>
        for (const id of ['container1', 'container2']) {
          const span = document.createElement('span');
          span.id = id + '-span';
          span.textContent = 'click me';
          span.style.display = 'block';
          span.style.position = 'absolute';
          span.style.left = '20px';
          span.style.top = '20px';
          span.style.width = '300px';
          span.style.height = '300px';
          span.addEventListener('click', () => window.__clicked = id);
          const div = document.getElementById(id);
          const host = div.attachShadow({ mode: 'open' });
          host.appendChild(span);
        }
      </script>
    """)

    {:error, error} = Locator.click(Page.locator(page, "#container1 >> text=click me"), timeout: 3000)
    assert Exception.message(error) =~ ~s[<div id="container2"></div> intercepts pointer events]
  end

  test "should detect overlaid element in a transformed iframe", %{page: page} do
    Page.set_content!(page, """
      <style>
        body, html, iframe { margin: 0; padding: 0; border: none; }
        iframe {
          border: 4px solid black;
          background: gray;
          margin-left: 33px;
          margin-top: 24px;
          width: 400px;
          height: 400px;
          transform: scale(1.2);
        }
      </style>
      <iframe srcdoc="
        <style>
          body, html { margin: 0; padding: 0; }
          div { margin-left: 10px; margin-top: 20px; width: 2px; height: 2px; }
          section { position: absolute; top: 0; left: 0; bottom: 0; right: 0; }
        </style>
        <div>Target</div>
        <section>Overlay</section>
        <script>
          document.querySelector('div').addEventListener('click', () => window.top._clicked = true);
        </script>
      "></iframe>
    """)

    locator = page |> Page.frame_locator("iframe") |> FrameLocator.locator("div")
    {:error, error} = Locator.click(locator, timeout: 5000)
    assert Exception.message(error) =~ "<section>Overlay</section> intercepts pointer events"
  end

  test "should click in iframe with padding", %{page: page} do
    Page.set_content!(page, """
      <style>
        body, html, iframe { margin: 0; padding: 0; border: none; box-sizing: border-box; }
        iframe { background: gray; width: 200px; height: 200px; padding-top: 100px; }
      </style>
      <iframe srcdoc="
        <style>
          body, html { margin: 0; padding: 0; }
          div { height: 100px; }
        </style>
        <div>Non-target</div>
        <div id=target>Target</div>
        <div>Non-target</div>
        <script>
          document.querySelector('#target').addEventListener('click', () => window.top._clicked = true);
        </script>
      "></iframe>
    """)

    locator = page |> Page.frame_locator("iframe") |> FrameLocator.locator("#target")
    Locator.click!(locator)
    assert Page.evaluate!(page, "window._clicked") == true
  end

  test "should click in iframe with padding 2", %{page: page} do
    Page.set_content!(page, """
      <style>
        body, html, iframe { margin: 0; padding: 0; border: none; box-sizing: content-box; }
        iframe { background: gray; width: 200px; height: 200px; padding-top: 100px; }
      </style>
      <iframe srcdoc="
        <style>
          body, html { margin: 0; padding: 0; }
          div { height: 100px; }
        </style>
        <div>Non-target</div>
        <div id=target>Target</div>
        <div>Non-target</div>
        <script>
          document.querySelector('#target').addEventListener('click', () => window.top._clicked = true);
        </script>
      "></iframe>
    """)

    locator = page |> Page.frame_locator("iframe") |> FrameLocator.locator("#target")
    Locator.click!(locator)
    assert Page.evaluate!(page, "window._clicked") == true
  end

  test "should click in custom element", %{page: page} do
    Page.set_content!(page, """
      <html>
        <body>
          <my-input></my-input>
          <script>
            class MyInput extends HTMLElement {
              connectedCallback() {
                this.attachShadow({mode:'open'});
                this.shadowRoot.innerHTML = '<div><span><input type="text" /></span></div>';
                this.shadowRoot.querySelector('input').addEventListener('click', () => window.__clicked = true);
              }
            }
            customElements.define('my-input', MyInput);
          </script>
        </body>
      </html>
    """)

    Locator.click!(Page.locator(page, "input"))
    assert Page.evaluate!(page, "window.__clicked") == true
  end

  # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/43118' }
  test "should click in nested custom elements", %{page: page} do
    Page.set_content!(page, """
      <outer-host></outer-host>
      <script>
        customElements.define('inner-host', class extends HTMLElement {
          connectedCallback() {
            this.attachShadow({ mode: 'open' }).innerHTML = '<inner-most></inner-most>';
          }
        });
        customElements.define('inner-most', class extends HTMLElement {
          connectedCallback() {
            this.attachShadow({ mode: 'open' }).innerHTML = '<input>';
            this.shadowRoot.querySelector('input').addEventListener('click', () => window.__clicked = true);
          }
        });
        customElements.define('outer-host', class extends HTMLElement {
          connectedCallback() {
            this.attachShadow({ mode: 'open' }).innerHTML = '<inner-host></inner-host>';
          }
        });
      </script>
    """)

    Locator.click!(Page.locator(page, "input"))
    assert Page.evaluate!(page, "window.__clicked") == true
  end

  # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/43118' }
  test "should click an element inside nested closed shadow roots", %{page: page} do
    Page.set_content!(page, """
      <div id=container></div>
      <script>
        const input = document.createElement('input');
        input.addEventListener('click', () => window.__clicked = true);
        const outer = document.getElementById('container').attachShadow({ mode: 'closed' });
        const inner = document.createElement('div');
        outer.appendChild(inner);
        inner.attachShadow({ mode: 'closed' }).appendChild(input);
        window.__target = input;
      </script>
    """)

    handle = Page.evaluate_handle!(page, "window.__target")
    ElementHandle.click!(JSHandle.as_element(handle))
    assert Page.evaluate!(page, "window.__clicked") == true
  end
end
