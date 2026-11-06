defmodule PlaywrightEx.Examples.WorkerTest do
  # Elixir translations of upstream's JS examples, rendered into the facade docs (see ExampleCase).
  use PlaywrightEx.ExampleCase, async: true

  alias PlaywrightEx.Promise
  alias PlaywrightEx.Worker

  @start_worker "() => { window.worker = new Worker(URL.createObjectURL(new Blob(['1'], { type: 'text/javascript' }))) }"

  example "Worker",
    js: ~S"""
    page.on('worker', worker => {
      console.log('Worker created: ' + worker.url());
      worker.on('close', worker => console.log('Worker destroyed: ' + worker.url()));
    });

    console.log('Current workers:');
    for (const worker of page.workers())
      console.log('  ' + worker.url());
    """,
    given: [_worker: Page.expect_worker!(page, fn -> Page.evaluate!(page, @start_worker) end)] do
    Page.on(page, :worker, fn worker ->
      IO.puts("Worker created: " <> Worker.url(worker))
      Worker.on(worker, :close, &IO.puts("Worker destroyed: " <> Worker.url(&1)))
    end)

    IO.puts("Current workers:")
    for worker <- Page.workers(page), do: IO.puts("  " <> Worker.url(worker))
  end

  example "Worker.waitForEvent",
    js: ~S"""
    // Start waiting for download before clicking. Note no await.
    const consolePromise = worker.waitForEvent('console');
    await worker.evaluate('console.log(42)');
    const consoleMessage = await consolePromise;
    """,
    given: [worker: Page.expect_worker!(page, fn -> Page.evaluate!(page, @start_worker) end)] do
    # Start waiting for download before clicking. Note no await.
    console_promise = Worker.wait_for_event(worker, :console)
    Worker.evaluate!(worker, "console.log(42)")
    console_message = Promise.await!(console_promise)
  end
end
