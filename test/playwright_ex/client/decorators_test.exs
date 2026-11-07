defmodule PlaywrightEx.Client.DecoratorsTest do
  use ExUnit.Case, async: true

  defmodule Receiver do
    @moduledoc false
    use PlaywrightEx.Client.Decorators

    defstruct [:test]

    # Records the options and whether the body runs inside the wrap.
    def _wrap_api_call(this, func, options) do
      Process.put(:in_wrap, true)
      send(this.test, {:wrap, options})
      func.(nil)
    after
      Process.delete(:in_wrap)
    end

    @api_call %{title: "Defaults"}
    def defaults(_this, options \\ nil) do
      options = options || %{in_wrap: Process.get(:in_wrap, false)}
      {:defaults, options}
    end

    @api_call %{}
    def clauses(_this, :one), do: :one
    def clauses(_this, other) when is_integer(other), do: {:int, other}

    def calls_private(this), do: private(this)

    @internal true
    defp private(_this), do: :private

    def plain(_this), do: Process.get(:in_wrap, false)
  end

  setup do
    %{this: %Receiver{test: self()}}
  end

  test "@api_call wraps the whole body, JS default parameters (applied in the body) included", %{this: this} do
    assert Receiver.defaults(this) == {:defaults, %{in_wrap: true}}
    assert_received {:wrap, %{title: "Defaults"}}
    assert Receiver.defaults(this, %{x: 1}) == {:defaults, %{x: 1}}
    assert_received {:wrap, %{title: "Defaults"}}
    refute_received {:wrap, _}
  end

  test "@api_call covers every clause; @internal works on private functions", %{this: this} do
    assert Receiver.clauses(this, :one) == :one
    assert Receiver.clauses(this, 2) == {:int, 2}
    assert_received {:wrap, %{}}
    assert_received {:wrap, %{}}

    assert Receiver.calls_private(this) == :private
    assert_received {:wrap, %{internal: true}}
  end

  test "an undecorated function is not wrapped", %{this: this} do
    refute Receiver.plain(this)
    refute_received {:wrap, _}
  end
end
