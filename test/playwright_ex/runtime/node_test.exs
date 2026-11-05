defmodule PlaywrightEx.Runtime.NodeTest do
  use ExUnit.Case, async: true

  alias PlaywrightEx.Runtime.Node

  test "path_resolve: as Node's path.resolve" do
    cwd = File.cwd!()
    assert Node.path_resolve("a/../b/./c/") == Path.join(cwd, "b/c")
    assert Node.path_resolve("~/x") == Path.join(cwd, "~/x")
    assert Node.path_resolve("/abs/x/..") == "/abs"
    assert Node.path_resolve(["/a", "b", "", "/c", "d"]) == "/c/d"
  end

  test "fs errors: Node's text and code" do
    error = assert_raise Node.SystemError, fn -> Node.fs!(File.stat("/no/such"), "stat", "/no/such") end
    assert error.message == "ENOENT: no such file or directory, stat '/no/such'"
    assert error.code == "ENOENT"
    assert Node.fs!(File.read(__ENV__.file), "open", __ENV__.file) =~ "defmodule"
  end
end
