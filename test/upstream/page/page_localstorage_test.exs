defmodule PlaywrightEx.Page.PageLocalstorageTest do
  @upstream "tests/page/page-localstorage.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Page
  alias PlaywrightEx.WebStorage

  @moduletag :page

  # it.skip(({ isElectron }) => !!isElectron, 'Electron shares a single context between tests');

  test "localStorage.items returns empty array on fresh origin", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    assert WebStorage.items!(Page.local_storage(page)) == []
  end

  test "localStorage.getItem returns null for missing key", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    assert WebStorage.get_item!(Page.local_storage(page), "absent") == nil
  end

  test "localStorage.setItem persists and surfaces in items()/getItem()", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    WebStorage.set_item!(Page.local_storage(page), "alpha", "1")
    WebStorage.set_item!(Page.local_storage(page), "beta", "2")

    assert MapSet.new(WebStorage.items!(Page.local_storage(page))) ==
             MapSet.new([%{name: "alpha", value: "1"}, %{name: "beta", value: "2"}])

    assert WebStorage.get_item!(Page.local_storage(page), "alpha") == "1"
    assert Page.evaluate!(page, "() => localStorage.getItem('alpha')") == "1"
  end

  test "localStorage.setItem overwrites existing value", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    WebStorage.set_item!(Page.local_storage(page), "k", "first")
    WebStorage.set_item!(Page.local_storage(page), "k", "second")
    assert WebStorage.get_item!(Page.local_storage(page), "k") == "second"
  end

  test "localStorage.removeItem removes a single item", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    WebStorage.set_item!(Page.local_storage(page), "a", "1")
    WebStorage.set_item!(Page.local_storage(page), "b", "2")

    WebStorage.remove_item!(Page.local_storage(page), "a")
    assert WebStorage.items!(Page.local_storage(page)) == [%{name: "b", value: "2"}]
  end

  test "localStorage.clear empties storage", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    WebStorage.set_item!(Page.local_storage(page), "a", "1")
    WebStorage.set_item!(Page.local_storage(page), "b", "2")

    WebStorage.clear!(Page.local_storage(page))
    assert WebStorage.items!(Page.local_storage(page)) == []
  end

  test "sessionStorage round-trip", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    assert WebStorage.items!(Page.session_storage(page)) == []

    WebStorage.set_item!(Page.session_storage(page), "s1", "v1")
    WebStorage.set_item!(Page.session_storage(page), "s2", "v2")

    assert MapSet.new(WebStorage.items!(Page.session_storage(page))) ==
             MapSet.new([%{name: "s1", value: "v1"}, %{name: "s2", value: "v2"}])

    assert WebStorage.get_item!(Page.session_storage(page), "s1") == "v1"

    WebStorage.remove_item!(Page.session_storage(page), "s1")
    assert WebStorage.items!(Page.session_storage(page)) == [%{name: "s2", value: "v2"}]

    WebStorage.clear!(Page.session_storage(page))
    assert WebStorage.items!(Page.session_storage(page)) == []
  end

  test "localStorage and sessionStorage are independent", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    WebStorage.set_item!(Page.local_storage(page), "shared", "local")
    WebStorage.set_item!(Page.session_storage(page), "shared", "session")

    assert WebStorage.get_item!(Page.local_storage(page), "shared") == "local"
    assert WebStorage.get_item!(Page.session_storage(page), "shared") == "session"

    WebStorage.clear!(Page.local_storage(page))
    assert WebStorage.items!(Page.local_storage(page)) == []
    assert WebStorage.get_item!(Page.session_storage(page), "shared") == "session"
  end

  test "storage methods are scoped to the current origin", %{page: page, server: server} do
    # it.skip(isAndroid, 'these are same origins on Android due to our test server limitation');
    Page.goto!(page, server.prefix <> "/empty.html")
    WebStorage.set_item!(Page.local_storage(page), "k", "origin-1")

    Page.goto!(page, server.cross_process_prefix <> "/empty.html")
    assert WebStorage.items!(Page.local_storage(page)) == []
    WebStorage.set_item!(Page.local_storage(page), "k", "origin-2")

    Page.goto!(page, server.prefix <> "/empty.html")
    assert WebStorage.get_item!(Page.local_storage(page), "k") == "origin-1"
  end
end
