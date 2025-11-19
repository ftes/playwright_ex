ExUnit.start()
timeout = Application.fetch_env!(:playwright_ex, :timeout)
{:ok, _} = PlaywrightEx.Supervisor.start_link(timeout: timeout)
