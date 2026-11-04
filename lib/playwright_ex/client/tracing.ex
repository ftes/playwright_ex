defmodule PlaywrightEx.Client.Tracing do
  @upstream "packages/playwright-core/src/client/tracing.ts"
  @moduledoc "Port of `#{@upstream}`: so far the HAR recording."
  use PlaywrightEx.Client.ChannelOwner

  alias PlaywrightEx.Client.Connection
  alias PlaywrightEx.Client.DisposableStub
  alias PlaywrightEx.Client.LocalUtils

  def from(channel) do
    channel
  end

  def new(parent, type, guid, initializer) do
    this = ChannelOwner.new(__MODULE__, parent, type, guid, initializer)
    put(this, :_includeSources, false)
    put(this, :_additionalSources, [])
    put(this, :_isLive, false)
    put(this, :_isTracing, false)
    # Map<harId, { path, resourcesDir }>
    put(this, :_harRecorders, %{})
    this
  end

  # start, startChunk, group, groupEnd, _startCollectingStacks, stopChunk, stop  -- not ported: trace recording

  def start_har(this, path, options \\ %{}) do
    options = options || %{}

    _wrap_api_call(this, fn _ ->
      if get(this, :_harId), do: raise("HAR recording has already been started")

      if options[:resourcesDir] && String.ends_with?(path, ".zip"),
        do: raise("resourcesDir option is not compatible with a .zip har file")

      default_content = if String.ends_with?(path, ".zip"), do: "attach", else: "embed"

      put(
        this,
        :_harId,
        _record_into_har(this, path, nil, %{
          url: options[:urlFilter],
          updateContent: if(options[:content] == nil, do: default_content, else: options.content),
          updateMode: if(options[:mode] == nil, do: "full", else: options.mode),
          resourcesDir: options[:resourcesDir]
        })
      )
    end)

    DisposableStub.new(fn -> stop_har(this) end)
  end

  def stop_har(this) do
    _wrap_api_call(this, fn _ ->
      har_id = get(this, :_harId)
      if !har_id, do: raise("HAR recording has not been started")
      put(this, :_harId, nil)
      _export_har(this, har_id)
    end)

    nil
  end

  def _record_into_har(this, har, page, options \\ %{}) do
    is_zip = String.ends_with?(har, ".zip")
    url = options[:url]

    %{harId: har_id} =
      channel_call(
        this,
        :harStart,
        %{
          page: page,
          options: %{
            content: options[:updateContent] || "attach",
            urlGlob: if(is_binary(url), do: url),
            urlRegexSource: if(is_struct(url, Regex), do: Regex.source(url)),
            urlRegexFlags: if(is_struct(url, Regex), do: PlaywrightEx.Protocol.Serializers.regex_flags(url)),
            mode: options[:updateMode] || "minimal",
            harPath: if(is_zip, do: nil, else: har),
            resourcesDir: options[:resourcesDir]
          }
        },
        TimeoutSettings.k_no_timeout()
      )

    update(this, :_harRecorders, &Map.put(&1, har_id, %{path: har, resourcesDir: options[:resourcesDir]}))
    har_id
  end

  def _export_har(this, har_id) do
    har_params = get(this, :_harRecorders)[har_id]

    if har_params do
      update(this, :_harRecorders, &Map.delete(&1, har_id))
      is_local = !Connection.is_remote(get(this, :_connection))
      is_zip = String.ends_with?(har_params.path, ".zip")

      if is_local do
        %{entries: entries} =
          channel_call(this, :harExport, %{harId: har_id, mode: "entries"}, TimeoutSettings.k_no_timeout())

        # Server wrote HAR and resources to the user's chosen paths.
        if is_zip do
          local_utils = Connection.local_utils(get(this, :_connection))
          if !local_utils, do: raise("Cannot save zipped HAR in thin clients")

          LocalUtils.zip(local_utils, %{
            zipFile: har_params.path,
            entries: entries,
            mode: "write",
            includeSources: false,
            additionalSources: []
          })
        end
      else
        # const { artifact } = await this._channel.harExport({ harId, mode: 'archive' }); saveAs, harUnzip  -- not ported: Artifact
        raise "HAR export over a remote connection is not supported yet"
      end
    end

    nil
  end

  def _export_all_hars(this) do
    _wrap_api_call(
      this,
      fn _ ->
        Promise.await(
          Promise.all(
            for har_id <- Map.keys(get(this, :_harRecorders)), do: Promise.async(fn -> _export_har(this, har_id) end)
          )
        )
      end,
      %{internal: true}
    )

    nil
  end

  # _doStopChunk, _saveChunk  -- not ported: trace recording

  def _reset_stack_counter(this) do
    if get(this, :_isTracing) do
      put(this, :_isTracing, false)
      Connection.set_is_tracing(get(this, :_connection), false)
    end
  end
end
