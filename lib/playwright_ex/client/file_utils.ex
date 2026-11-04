defmodule PlaywrightEx.Client.FileUtils do
  @upstream "packages/playwright-core/src/client/fileUtils.ts"
  @moduledoc "Port of `#{@upstream}`."

  # Keep in sync with the server.
  def file_upload_size_limit, do: 50 * 1024 * 1024

  def mkdir_if_needed(file_path) do
    # This will harmlessly throw on windows if the dirname is the root directory.
    _ = File.mkdir_p(Path.dirname(file_path))
    nil
  end
end
