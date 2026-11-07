defmodule PlaywrightEx.Page.ElementhandleClickTest do
  @upstream "tests/page/elementhandle-click.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.ElementHandle
  alias PlaywrightEx.Page

  @moduletag :page

  test "EH-010 should work @smoke", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/button.html")
    button = Page.query_selector!(page, "button")
    ElementHandle.click!(button)
    assert Page.evaluate!(page, "() => window['result']") == "Clicked"
  end

  test "EH-011 should work with Node removed", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/button.html")
    Page.evaluate!(page, "() => delete window['Node']")
    button = Page.query_selector!(page, "button")
    ElementHandle.click!(button)
    assert Page.evaluate!(page, "() => window['result']") == "Clicked"
  end

  test "EH-012 should work for Shadow DOM v1", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/shadow.html")
    button_handle = Page.evaluate_handle!(page, "() => window['button']")
    ElementHandle.click!(button_handle)
    assert Page.evaluate!(page, "clicked") == true
  end

  test "EH-013 should work for TextNodes", %{page: page} do
    Page.set_content!(page, """
    <div id='outer' onclick="window['result'] = 'Clicked ' + event.target.id;">
      <div id='inner' style="max-width: 50px">Lorem ipsum dolor sit amet consectetur adipiscing elit proin, integer curabitur imperdiet rhoncus cursus tincidunt bibendum, consequat sed magnis laoreet luctus mollis tellus. Nisl parturient mus accumsan feugiat sem laoreet magnis nisi, aptent per sollicitudin gravida orci ac blandit, viverra eros praesent auctor vivamus semper bibendum. Consequat sed habitasse luctus dictumst gravida platea semper phasellus, nascetur ridiculus purus est varius quisque et scelerisque, id vehicula eleifend montes sollicitudin dis velit. Pellentesque ridiculus per natoque et eleifend taciti nunc, laoreet auctor at condimentum imperdiet ante, conubia mi cubilia scelerisque sociosqu sem.</div>
      Custom Text.
    </div>
    """)

    button_text_node = Page.evaluate_handle!(page, "() => document.querySelector('#outer').lastChild")
    ElementHandle.click!(button_text_node)
    assert Page.evaluate!(page, "() => window['result']") == "Clicked outer"
  end

  test "EH-014 should throw for detached nodes", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/button.html")
    button = Page.query_selector!(page, "button")
    Page.evaluate!(page, "button => button.remove()", button)
    {:error, error} = ElementHandle.click(button)
    assert Exception.message(error) =~ "Element is not attached to the DOM"
  end

  test "EH-015 should throw for hidden nodes with force", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/button.html")
    button = Page.query_selector!(page, "button")
    Page.evaluate!(page, "button => button.style.display = 'none'", button)
    {:error, error} = ElementHandle.click(button, force: true)
    assert Exception.message(error) =~ "Element is not visible"
  end

  test "EH-016 should throw for recursively hidden nodes with force", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/button.html")
    button = Page.query_selector!(page, "button")
    Page.evaluate!(page, "button => button.parentElement.style.display = 'none'", button)
    {:error, error} = ElementHandle.click(button, force: true)
    assert Exception.message(error) =~ "Element is not visible"
  end

  test "EH-017 should throw for <br> elements with force", %{page: page} do
    Page.set_content!(page, "hello<br>goodbye")
    br = Page.query_selector!(page, "br")
    {:error, error} = ElementHandle.click(br, force: true)
    assert Exception.message(error) =~ "Element is outside of the viewport"
  end

  test "EH-018 should double click the button", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/button.html")

    Page.evaluate!(page, """
    () => {
      window['double'] = false;
      const button = document.querySelector('button');
      button.addEventListener('dblclick', event => {
        window['double'] = true;
      });
    }
    """)

    button = Page.query_selector!(page, "button")
    ElementHandle.dblclick!(button)
    assert Page.evaluate!(page, "double") == true
    assert Page.evaluate!(page, "result") == "Clicked"
  end
end
