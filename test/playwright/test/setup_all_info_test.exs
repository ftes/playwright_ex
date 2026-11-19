defmodule Playwright.Test.SetupAllInfoTest do
  # `Playwright.Test.info/0` in a module's `setup_all`: the fields that apply to the module, its
  # options resolved from the config, its project and the module, never a describe's or a
  # test's. Sync, so the config set here reaches no other module.
  use ExUnit.Case,
    async: false,
    parameterize: [Playwright.Test.parameters(locale: "fr-FR", base_url: "http://project.test")]

  alias Playwright.Test

  @test_keys [:test_pid, :test_name, :output_dir, :retry, :deadline, :close_deadline]

  # Before `use Playwright.Test`, whose `setup_all` reads the config.
  setup_all do
    config = Application.get_env(:playwright, :test)
    on_exit(fn -> Application.put_env(:playwright, :test, config) end)

    Application.put_env(
      :playwright,
      :test,
      Keyword.merge(config,
        base_url: "http://config.test",
        locale: "de-DE",
        timezone_id: "Asia/Tokyo",
        action_timeout: 4321
      )
    )

    :ok
  end

  # The module's `base_url: nil` falls back to the project's.
  use Playwright.Test, timezone_id: "Europe/Berlin", base_url: nil

  @moduletag Test.use(navigation_timeout: 1234)
  @moduletag timeout: 23_456

  setup_all do
    raised = fn fun ->
      try do
        fun.()
        :ok
      rescue
        error -> Exception.message(error)
      end
    end

    in_task =
      Task.await(
        Task.async(fn ->
          %{info: Test.info(), scope?: Test.in_registered_scope?(), test?: Test.in_registered_test?()}
        end)
      )

    %{
      setup_all: %{
        info: Test.info(),
        scope?: Test.in_registered_scope?(),
        test?: Test.in_registered_test?(),
        task: in_task,
        output_path: raised.(fn -> Test.output_path("x.txt") end),
        snapshot_path: raised.(fn -> Test.snapshot_path("x.png") end),
        attach: raised.(fn -> Test.attach("x", body: "x") end),
        step: raised.(fn -> Test.step("x", do: :ok) end)
      }
    }
  end

  test "info: the module's fields, the test's absent", %{setup_all: setup_all} do
    info = setup_all.info
    assert info.file == Path.expand(__ENV__.file)
    assert info.timeout == if(ExUnit.configuration()[:trace], do: :infinity, else: 23_456)
    for key <- @test_keys, do: refute(Map.has_key?(info, key))
    assert setup_all.scope?
    refute setup_all.test?
  end

  test "info: the layers, config < project < module use < @moduletag", %{setup_all: %{info: info}} do
    # The config's.
    assert info.use.action_timeout == 4321
    # The project's over the config's.
    assert info.use.locale == "fr-FR"
    # The module's `use` over both.
    assert info.use.timezone_id == "Europe/Berlin"
    # The module's `nil`: the project's.
    assert info.use.base_url == "http://project.test"
    # The module's `@moduletag`.
    assert info.use.navigation_timeout == 1234
    # Playwright Test's defaults, a mode and the worker's.
    assert info.use.viewport == %{width: 1280, height: 720}
    assert info.use.trace == Test.config().trace
    assert info.use.browser_name == String.to_existing_atom(Playwright.TestBrowser.name())
  end

  test "info: in a Task of setup_all, the same", %{setup_all: setup_all} do
    assert setup_all.task.info == setup_all.info
    assert setup_all.task.scope?
    refute setup_all.task.test?
  end

  test "info: a test outside a describe resolves the same use", %{setup_all: setup_all} do
    assert Test.info().use == setup_all.info.use
    assert Test.info().file == setup_all.info.file
  end

  describe "a describe's options" do
    @describetag Test.use(locale: "es-ES")

    test "reach the test, not setup_all", %{setup_all: setup_all} do
      assert Test.info().use.locale == "es-ES"
      assert setup_all.info.use.locale == "fr-FR"
    end
  end

  test "the test's own functions raise in setup_all", %{setup_all: setup_all} do
    assert "Playwright.Test.output_path/1 can only be called while a test is running: in a test of a module" <> _ =
             setup_all.output_path

    assert "Playwright.Test.snapshot_path/2 can only be called while a test is running: in a test of a module" <> _ =
             setup_all.snapshot_path

    assert "Playwright.Test.attach/2 can only be called while a test is running: in a test of a module" <> _ =
             setup_all.attach

    assert setup_all.step == "test.step() can only be called from a test"
  end

  test "in_registered_scope?: in the test and its Tasks, not in other processes" do
    assert Test.in_registered_scope?()
    assert Task.await(Task.async(&Test.in_registered_scope?/0))
    test_pid = self()
    spawn(fn -> send(test_pid, {:scope?, Test.in_registered_scope?()}) end)
    assert_receive {:scope?, false}
  end
end

defmodule Playwright.Test.SetupAllInfoTest.Unregistered do
  # Without `use Playwright.Test`: no scope, so `info/0` raises in `setup_all` too.
  use ExUnit.Case, async: true

  setup_all do
    %{scope?: Playwright.Test.in_registered_scope?(), raised: catch_error(Playwright.Test.info())}
  end

  test "info raises in setup_all without use Playwright.Test", ctx do
    refute ctx.scope?

    assert %RuntimeError{message: "Playwright.Test.info() can only be called while a test or its module" <> _} =
             ctx.raised
  end
end
