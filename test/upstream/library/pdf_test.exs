defmodule PlaywrightEx.Library.PdfTest do
  @upstream "tests/library/pdf.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  @browser_name System.get_env("BROWSER", "chromium")

  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Page

  @tag :tmp_dir
  @tag skip:
         if(@browser_name != "chromium", do: "upstream skip: Printing to pdf is currently only supported in chromium.")
  test "PD-001 should be able to save file", %{context_factory: context_factory, tmp_dir: tmp_dir} do
    context = context_factory.([])
    page = BrowserContext.new_page!(context)
    output_file = Path.join(tmp_dir, "output.pdf")
    Page.pdf!(page, path: output_file)
    assert File.stat!(output_file).size > 0
  end

  @tag :tmp_dir
  @tag skip:
         if(@browser_name != "chromium", do: "upstream skip: Printing to pdf is currently only supported in chromium.")
  test "PD-002 should be able to generate outline", %{
    context_factory: context_factory,
    server: server,
    tmp_dir: tmp_dir
  } do
    context = context_factory.(base_url: server.prefix)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, "/headings.html")
    output_file_no_outline = Path.join(tmp_dir, "outputNoOutline.pdf")
    output_file_outline = Path.join(tmp_dir, "outputOutline.pdf")
    Page.pdf!(page, path: output_file_no_outline)
    Page.pdf!(page, path: output_file_outline, tagged: true, outline: true)
    assert File.stat!(output_file_outline).size > File.stat!(output_file_no_outline).size
  end
end
