defmodule PlaywrightEx.Page.PageTransitionTest do
  @upstream "tests/page/page-transition.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  @browser_name System.get_env("BROWSER", "chromium")

  alias PlaywrightEx.Page

  @moduletag :page

  defp crashed? do
    receive do
      :crashed ->
        send(self(), :crashed)
        true
    after
      0 -> false
    end
  end

  @tag skip:
         if(@browser_name == "webkit",
           do: "upstream fixme: Web process crashes on the compositor thread when a filter transitions to none"
         )
  test "PA-038 should not crash when filter transition completes", %{page: page} do
    # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/42637' }
    # it.fixme(browserName === 'webkit', 'Web process crashes on the compositor thread when a filter transitions to none')
    Page.set_content!(page, """
      <style>
        div { transition: filter 0.1s; }
        .dim { filter: brightness(0.95); }
      </style>
      #{String.duplicate("<div>hello</div>", 10)}
    """)

    test = self()
    Page.on(page, :crash, fn _ -> send(test, :crashed) end)

    Enum.reduce_while(1..10, nil, fn _, _ ->
      if crashed?() do
        {:halt, nil}
      else
        Page.evaluate(page, """
        async () => {
          const divs = [...document.querySelectorAll('div')];
          const settled = () => Promise.all(divs.map(div => new Promise(f => div.addEventListener('transitionend', f, { once: true }))));
          let promise = settled();
          divs.forEach(div => div.classList.add('dim'));
          await promise;
          promise = settled();
          divs.forEach(div => div.classList.remove('dim'));
          await promise;
        }
        """)

        {:cont, nil}
      end
    end)

    refute crashed?()
  end
end
