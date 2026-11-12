defmodule LiveViewE2E.Utils do
  @moduledoc "`utils.js`."

  alias PlaywrightEx.{APIRequestContext, APIResponse, Expect, Locator, Page}

  def random_string(size \\ 21) do
    size |> :crypto.strong_rand_bytes() |> Base.encode64() |> binary_part(0, size)
  end

  # a helper function to wait until the LV has no pending events
  # (upstream awaits the four with Promise.all; one after another waits as long)
  def sync_lv(page) do
    page |> Page.locator(".phx-connected") |> Locator.first() |> Expect.to_be_visible!()
    page |> Page.locator(".phx-change-loading") |> Expect.to_have_count!(0)
    page |> Page.locator(".phx-click-loading") |> Expect.to_have_count!(0)
    page |> Page.locator(".phx-submit-loading") |> Expect.to_have_count!(0)
  end

  # this function executes the given code inside the liveview that is responsible
  # for the given selector; it uses private phoenix live view js functions, so it could
  # break in the future
  # we handle the evaluation in a LV hook
  def eval_lv(page, code, selector \\ "[data-phx-main]") do
    Page.evaluate!(
      page,
      """
      ([code, selector]) => {
        return new Promise((resolve) => {
          window.liveSocket.main.withinTargets(
            selector,
            (targetView, targetCtx) => {
              targetView.pushEvent(
                "event",
                document.body,
                targetCtx,
                "sandbox:eval",
                { value: code },
                {},
                ({ result }) => resolve(result),
              );
            },
          );
        });
      }
      """,
      [code, selector]
    )
  end

  # executes the given code inside a new process
  # (in context of a plug request)
  def eval_plug(request, code) do
    request |> APIRequestContext.post!("/eval", data: %{code: code}) |> APIResponse.json!()
  end

  @doc """
  Playwright Test's `expect(fn).toPass()`, which PlaywrightEx (a client, not a runner) lacks:
  retries `fun` until it doesn't raise, at upstream's intervals, until `timeout` (upstream's
  default 0 waits until the test times out).
  """
  def to_pass(fun, opts \\ []) do
    deadline =
      case Keyword.get(opts, :timeout, 0) do
        0 -> :infinity
        timeout -> System.monotonic_time(:millisecond) + timeout
      end

    retry(fun, deadline, Keyword.get(opts, :intervals, [100, 250, 500, 1000]))
  end

  defp retry(fun, deadline, intervals) do
    fun.()
  rescue
    error ->
      [interval | rest] = intervals

      if deadline != :infinity and System.monotonic_time(:millisecond) + interval >= deadline do
        reraise error, __STACKTRACE__
      end

      Process.sleep(interval)
      retry(fun, deadline, if(rest == [], do: [interval], else: rest))
  end

  # Upstream starts an evaluate that resolves when the returned function is called, and keeps
  # acting meanwhile. PlaywrightEx has no un-awaited call (a Task would race the next action),
  # so this installs the observer with one evaluate and collects with a second.
  def attribute_mutations(page, selector) do
    id = "mutations_" <> (random_string(24) |> String.replace(~r/[^A-Za-z0-9]/, "_"))

    page
    |> Page.locator(selector)
    |> Locator.evaluate!(
      """
      (target, id) => {
        const mutations = [];
        const observer = new MutationObserver((mutationsList, _observer) => {
          mutationsList.forEach((mutation) => {
            if (mutation.type === "attributes") {
              mutations.push({
                attr: mutation.attributeName,
                oldValue: mutation.oldValue,
                newValue: mutation.target.getAttribute(mutation.attributeName),
              });
            }
          });
        });
        observer.observe(target, { attributes: true, attributeOldValue: true });
        window[id] = () => {
          observer.disconnect();
          delete window[id];
          return mutations;
        };
      }
      """,
      id
    )

    fn ->
      page |> Page.locator(selector) |> Locator.evaluate!("(_target, id) => window[id]()", id)
    end
  end
end
