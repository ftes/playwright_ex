defmodule PlaywrightEx.Library.Events.NumArgsTest do
  @upstream "tests/library/events/num-args.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  @tag skip:
         "not ported: rest parameters and `arguments.length` (Elixir functions have a fixed arity; emit passes one argument)"
  test "should work"
end
