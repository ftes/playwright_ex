defmodule PlaywrightEx.OptionalMimeTest do
  use ExUnit.Case, async: true

  @tag :tmp_dir
  test "file fulfillment works without MIME and respects explicit content types", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "fixture.js")
    File.write!(path, "window.loaded = true;")

    # A separate VM excludes MIME without unloading modules used by other tests.
    script = """
    false = Code.ensure_loaded?(MIME)
    [path] = System.argv()

    for {opts, expected} <- [
      {[path: path], "application/octet-stream"},
      {[path: path, content_type: "application/javascript"], "application/javascript"},
      {[path: path, headers: %{"Content-Type" => "text/javascript"}], "text/javascript"}
    ] do
      connection = spawn(fn ->
        receive do
          {:"$gen_call", from, {:send, %{params: params}}} ->
            GenServer.reply(from, %{result: params})
        end
      end)

      route = %PlaywrightEx.Route{guid: "route", owner: self(), connection: connection, timeout: 1_000}
      Process.put({PlaywrightEx.Route, route.guid}, false)
      {:ok, response} = PlaywrightEx.Route.fulfill(route, opts)
      %{value: ^expected} = Enum.find(response.headers, &(&1.name == "content-type"))
      "window.loaded = true;" = Base.decode64!(response.body)
    end
    """

    args =
      Enum.flat_map([:playwright_ex, :nimble_options], fn app ->
        ["-pa", Application.app_dir(app, "ebin")]
      end) ++ ["-e", script, "--", path]

    assert {_, 0} = System.cmd(System.find_executable("elixir"), args, stderr_to_stdout: true)
  end
end
