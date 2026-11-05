defmodule PlaywrightEx.UpstreamSnapshot do
  @upstream "packages/playwright/src/matchers/toMatchSnapshot.ts"
  @moduledoc """
  The test runner's `expect(buffer).toMatchSnapshot(name, options)` (`#{@upstream}`) for the
  mirrored specs: `to_match_snapshot(buffer, name, options)` inside a test of a module with
  `@upstream "tests/<path>.spec.ts"`.

  The snapshot path follows upstream's `tests/library/playwright.config.ts`
  `snapshotPathTemplate` (`{testFileDir}/{testFileName}-snapshots/{arg}-${browserName}{ext}`,
  `testInfo._resolveSnapshotPaths`): `to_match_snapshot(buffer, "grid-cell-1.png")` in
  `tests/page/page-screenshot.spec.ts` compares against upstream's
  `tests/page/page-screenshot.spec.ts-snapshots/grid-cell-1-chromium.png` (no platform suffix).

  The comparison is upstream's own: `utils.getComparator(mimeType)` of the driver package's
  `lib/coreBundle.js` (as upstream's `tests/config/comparator.ts` requires it), run by the
  driver's node (`PlaywrightEx.Driver.executable/0`), so `threshold`, `maxDiffPixels`,
  `maxDiffPixelRatio` and `comparator` (options with the JS keys) behave as upstream's.

  Deviations: there is no `updateSnapshots`, a missing snapshot fails (the runner's `"none"`
  mode). On a mismatch the `-actual` and `-diff` files are written to a temp dir named in the
  failure. `.not`, string snapshots and anonymous (index-named) snapshots are not ported (unused).
  """

  import ExUnit.Assertions

  # Reads the actual and expected files, prints the comparator's `{ errorMessage }` (or `null`) and
  # writes the diff (the comparator returns it as a PNG Buffer) to the given path.
  @compare_js """
  const [coreBundle, mimeType, actualPath, expectedPath, options, diffPath] = process.argv.slice(1);
  const fs = require('fs');
  const { utils } = require(coreBundle);
  const result = utils.getComparator(mimeType)(fs.readFileSync(actualPath), fs.readFileSync(expectedPath), JSON.parse(options));
  if (result && result.diff)
    fs.writeFileSync(diffPath, result.diff);
  process.stdout.write(JSON.stringify(result ? { errorMessage: result.errorMessage } : null));
  """

  @doc "`expect(buffer).toMatchSnapshot(name, options)` of the calling module's `@upstream` spec."
  defmacro to_match_snapshot(buffer, name, options \\ quote(do: %{})) do
    spec = Module.get_attribute(__CALLER__.module, :upstream) || raise "to_match_snapshot/3 needs @upstream"

    quote do
      PlaywrightEx.UpstreamSnapshot.match!(unquote(spec), unquote(buffer), unquote(name), unquote(options))
    end
  end

  @doc false
  def match!(spec, received, name, options) do
    expected_path = snapshot_path(spec, name)
    options = Map.new(options)

    if options[:maxDiffPixels] != nil and options.maxDiffPixels < 0,
      do: raise("`maxDiffPixels` option value must be non-negative integer")

    if options[:maxDiffPixelRatio] != nil and (options.maxDiffPixelRatio < 0 or options.maxDiffPixelRatio > 1),
      do: raise("`maxDiffPixelRatio` option value must be between 0 and 1")

    if !File.exists?(expected_path), do: flunk("A snapshot doesn't exist at #{expected_path}.")

    case compare(mime_type(expected_path), received, expected_path, options) do
      {nil, _} -> true
      {error_message, output_dir} -> flunk("#{Path.basename(expected_path)}: #{error_message}\n\nOutput: #{output_dir}")
    end
  end

  @doc "`testInfo.snapshotPath(name)`: the upstream golden file for the current `BROWSER`."
  def snapshot_path(spec, name) do
    ext = Path.extname(name)
    base = String.slice(name, 0, String.length(name) - String.length(ext))
    browser_name = System.get_env("BROWSER", "chromium")
    Path.join(PlaywrightEx.Upstream.dir(), "#{spec}-snapshots/#{sanitize_for_file_path(base)}-#{browser_name}#{ext}")
  end

  # utils/fileUtils.ts sanitizeForFilePath
  defp sanitize_for_file_path(s), do: String.replace(s, ~r/[\x00-\x2C\x2E-\x2F\x3A-\x40\x5B-\x60\x7B-\x7F]+/, "-")

  defp mime_type(path) do
    case Path.extname(path) do
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".webp" -> "image/webp"
    end
  end

  defp compare(mime_type, received, expected_path, options) do
    {node, [cli | _]} = PlaywrightEx.Driver.executable()
    core_bundle = Path.join(Path.dirname(cli), "lib/coreBundle.js")
    output_dir = Path.join(System.tmp_dir!(), "playwright_ex-snapshot-#{System.unique_integer([:positive])}")
    File.mkdir_p!(output_dir)
    ext = Path.extname(expected_path)
    actual_path = Path.join(output_dir, Path.basename(expected_path, ext) <> "-actual" <> ext)
    diff_path = Path.join(output_dir, Path.basename(expected_path, ext) <> "-diff.png")
    File.write!(actual_path, received)

    args = ["-e", @compare_js, core_bundle, mime_type, actual_path, expected_path, JSON.encode!(options), diff_path]
    {out, 0} = System.cmd(node, args)

    case JSON.decode!(out) do
      nil ->
        File.rm_rf!(output_dir)
        {nil, nil}

      %{"errorMessage" => error_message} ->
        {error_message, output_dir}
    end
  end
end
