defmodule Playwright.Test.Assertions do
  @moduledoc """
  ExUnit's `assert/1,2` and `refute/1,2`, each also recorded as an `expect` step of the running
  test, as upstream's `expect(value).toBe(...)` is (`Expect "assert"`). Elixir only: upstream's
  assertions are its matchers.

  `use Playwright.Test` imports them in place of `ExUnit.Assertions`' (with `assert_steps:
  false`, ExUnit's own). A helper module opts in with

      import ExUnit.Assertions, except: [assert: 1, assert: 2, refute: 1, refute: 2]
      import Playwright.Test.Assertions

  (the first line only if it imports `ExUnit.Assertions`). A library with its own `assert/2`
  excludes exactly the arities it defines (`import Playwright.Test.Assertions, except: [assert:
  2]`). ExUnit's `refute match?(...)` calls an unqualified `refute(value, expr: ..., ...)`, so a
  library's own `refute/2` takes that form too (delegating it to `refute/2` here). It can tell
  whether a module has these from `Playwright.Test.Assertions` in `__CALLER__.macros`. See "Assertions" in
  `Playwright.Test`.
  """

  @doc """
  `ExUnit.Assertions.assert/1`, also a step of the running test (`category: 'expect'`), as
  upstream's `expect(value).toBe(...)` is: `Expect "assert"`, with the expression as its
  subtitle and its `expression` param. It expands to ExUnit's `assert`, then records the step,
  so the assertion binds and fails as ExUnit's (see "Assertions" in `Playwright.Test`).
  """
  defmacro assert(assertion), do: plain_assertion_ast(:assert, assertion, __CALLER__)

  @doc """
  `ExUnit.Assertions.assert/2`, also a step of the running test, titled by the `message`, as
  upstream's `expect(value, message)` is. See `assert/1`.
  """
  defmacro assert(value, message), do: assertion_ast(:assert, value, message)

  @doc "`ExUnit.Assertions.refute/1`, also a step of the running test: `Expect \"refute\"`. See `assert/1`."
  defmacro refute(assertion), do: plain_assertion_ast(:refute, assertion, __CALLER__)

  @doc "`ExUnit.Assertions.refute/2`, also a step of the running test, titled by the `message`. See `assert/1`."
  defmacro refute(value, message), do: assertion_ast(:refute, value, message)

  # Elixir only: ExUnit's macro as it is (no `fn` or `try` around it, which would scope its
  # bindings), then the passed assertion's step. A failed one is recorded where its error is
  # caught (`__assertion_error__/2`). The step's `expected`, as upstream's `toEqual(expected)`, is
  # the value ExUnit's expansion binds to its `right` (of `left == right` and the other operators,
  # `pattern = right`, `match?(pattern, right)`): this expands ExUnit's macro once, here, and
  # reads that variable after it (`right_var/1`), so nothing is evaluated twice and ExUnit's
  # code is unchanged; an expansion that binds none (a truthy `assert x`) records none.
  defp plain_assertion_ast(kind, assertion, caller) do
    code = __code_string__(assertion)
    {:ok, env} = Macro.Env.define_require(caller, [], ExUnit.Assertions)
    expansion = Macro.expand_once(quote(do: ExUnit.Assertions.unquote(kind)(unquote(assertion))), env)

    quote do
      value = unquote(expansion)
      Playwright.Test.__assertion__(unquote(kind), unquote(code), nil, nil, unquote(right_var(expansion)))
      value
    end
  end

  # Elixir only: the assertion's source, a capture's argument as written (`&1`, not its variable,
  # `_&`), as in `Expect.poll!(fn, &assert(&1 == 2))`. A failed one's `expr` has no metadata (no
  # `capture:` index): it keeps ExUnit's `_&`.
  @doc false
  def __code_string__(quoted) do
    quoted
    |> Macro.prewalk(fn
      {:"_&", meta, :elixir_fn} = var -> if index = meta[:capture], do: {:&, [], [index]}, else: var
      node -> node
    end)
    |> Macro.to_string()
  end

  # The `right` ExUnit's expansion binds in the caller's scope: `right = ...` at the top of its
  # block, or of the block `refute` negates (`!`, whose argument's bindings stay bound). That
  # variable itself, with its hygiene counter, as `Macro.var(:right, ExUnit.Assertions)` is
  # another; `nil` for any other expansion (also a future ExUnit's that binds it otherwise).
  defp right_var({:__block__, _meta, exprs}) do
    Enum.find_value(exprs, fn
      {:=, _, [{:right, _, ExUnit.Assertions} = var, _value]} -> var
      _expr -> nil
    end)
  end

  defp right_var({:!, _meta, [expansion]}), do: right_var(expansion)
  defp right_var(_expansion), do: nil

  # ExUnit's own options (its `refute match?(...)` calls an unquoted `refute/2` with them, which
  # resolves to this one): ExUnit's function, as the assertion that expands to it is the step.
  defp assertion_ast(kind, value, opts) when is_list(opts) and opts != [] do
    if Keyword.keyword?(opts) and Keyword.has_key?(opts, :expr) do
      quote do
        require ExUnit.Assertions
        ExUnit.Assertions.unquote(kind)(unquote(value), unquote(opts))
      end
    else
      message_assertion_ast(kind, value, opts)
    end
  end

  defp assertion_ast(kind, value, message), do: message_assertion_ast(kind, value, message)

  # ExUnit's `assert/2` and `refute/2` are functions: their arguments are evaluated first, so
  # a `try` around the call alone binds nothing and keeps its stacktrace. A failure is recorded
  # there, also when the test rescues it.
  defp message_assertion_ast(kind, value, message) do
    code = __code_string__(value)

    quote do
      require ExUnit.Assertions
      value = unquote(value)
      message = unquote(message)

      result =
        try do
          ExUnit.Assertions.unquote(kind)(value, message)
        catch
          class, reason ->
            error = {class, reason, __STACKTRACE__}
            Playwright.Test.__assertion__(unquote(kind), unquote(code), message, error, nil)
            :erlang.raise(class, reason, __STACKTRACE__)
        end

      Playwright.Test.__assertion__(unquote(kind), unquote(code), message, nil, nil)
      result
    end
  end
end
