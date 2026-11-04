# The 100ms default is too tight for messages from freshly spawned processes on loaded CI runners.
ExUnit.start(assert_receive_timeout: 1_000)
{:ok, _} = PlaywrightEx.Supervisor.start_link(Application.get_all_env(:playwright_ex))
