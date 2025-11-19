defmodule PlaywrightEx.Tracing do
  @moduledoc """
  Interact with a Playwright `Tracing`.

  There is no official documentation, since this is considered Playwright internal.

  References:
  - https://github.com/microsoft/playwright/blob/main/packages/playwright-core/src/client/tracing.ts
  """

  import PlaywrightEx.Connection, only: [post: 2]
  import PlaywrightEx.Result, only: [from_response: 2]

  def tracing_start(tracing_id, opts \\ []) do
    params = Enum.into(opts, %{screenshots: true, snapshots: true, sources: true})

    %{guid: tracing_id, method: :tracing_start, params: params}
    |> post(opts[:timeout])
    |> from_response(& &1)
  end

  def tracing_start_chunk(tracing_id, opts \\ []) do
    %{guid: tracing_id, method: :tracing_start_chunk, params: Map.new(opts)}
    |> post(opts[:timeout])
    |> from_response(& &1)
  end

  def tracing_stop(tracing_id, opts \\ []) do
    %{guid: tracing_id, method: :tracing_stop, params: Map.new(opts)}
    |> post(opts[:timeout])
    |> from_response(& &1)
  end

  def tracing_stop_chunk(tracing_id, opts \\ []) do
    params = Enum.into(opts, %{mode: :archive})

    %{guid: tracing_id, method: :tracing_stop_chunk, params: params}
    |> post(opts[:timeout])
    |> from_response(& &1.result.artifact.guid)
  end
end
