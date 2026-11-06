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

  The same node bridge serves the specs' other image helpers: `compare_pngs/3`
  (`tests/config/comparator.ts`), `compare/2` (`utils.compare`) and `decode_image/2`
  (`utils.decodeWebp`, `PNG.sync.read`).
  """

  import ExUnit.Assertions

  # Prints the comparator's `{ errorMessage }` (or `null`) and writes its diff (a PNG Buffer).
  @compare_js """
  const [mimeType, actualPath, expectedPath, options, diffPath] = args;
  const result = utils.getComparator(mimeType)(fs.readFileSync(actualPath), fs.readFileSync(expectedPath), JSON.parse(options));
  if (result && result.diff && diffPath)
    fs.writeFileSync(diffPath, result.diff);
  out(result ? { errorMessage: result.errorMessage } : null);
  """

  @decode_js """
  const [type, path] = args;
  const buffer = fs.readFileSync(path);
  const { width, height, data } = type === 'webp' ? utils.decodeWebp(buffer) : require(utilsBundle).PNG.sync.read(buffer);
  out({ width, height, data: Buffer.from(data).toString('base64') });
  """

  @count_js """
  const [path1, path2] = args;
  const { PNG } = require(utilsBundle);
  const [image1, image2] = [path1, path2].map(path => PNG.sync.read(fs.readFileSync(path)));
  out(utils.compare(image1.data, image2.data, null, image1.width, image2.height));
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

    output_dir = tmp_dir()
    ext = Path.extname(expected_path)
    actual_path = Path.join(output_dir, Path.basename(expected_path, ext) <> "-actual" <> ext)
    diff_path = Path.join(output_dir, Path.basename(expected_path, ext) <> "-diff.png")
    File.write!(actual_path, received)

    case node!(@compare_js, [mime_type(ext), actual_path, expected_path, JSON.encode!(options), diff_path]) do
      nil ->
        File.rm_rf!(output_dir)
        true

      %{"errorMessage" => error_message} ->
        flunk("#{Path.basename(expected_path)}: #{error_message}\n\nOutput: #{output_dir}")
    end
  end

  @doc "`testInfo.snapshotPath(name)`: the upstream golden file for the current `BROWSER`."
  def snapshot_path(spec, name) do
    ext = Path.extname(name)
    base = String.slice(name, 0, String.length(name) - String.length(ext))
    browser_name = PlaywrightEx.TestBrowser.name()
    Path.join(PlaywrightEx.Upstream.dir(), "#{spec}-snapshots/#{sanitize_for_file_path(base)}-#{browser_name}#{ext}")
  end

  @doc """
  `comparePNGs(actual, expected, options)` of upstream `tests/config/comparator.ts`: `nil` when
  the images match, else `%{"errorMessage" => _}`.
  """
  def compare_pngs(actual, expected, options \\ %{}) do
    # Strict threshold by default in our tests.
    options = Map.merge(%{comparator: "ssim-cie94", threshold: 0}, Map.new(options))
    dir = tmp_dir()
    [actual_path, expected_path] = for {b, n} <- [{actual, "actual"}, {expected, "expected"}], do: write!(dir, n, b)

    try do
      node!(@compare_js, ["image/png", actual_path, expected_path, JSON.encode!(options), ""])
    after
      File.rm_rf!(dir)
    end
  end

  @doc """
  `utils.decodeWebp(buffer)` (`type` `:webp`) or `PNG.sync.read(buffer)` (`:png`):
  `%{width: _, height: _, data: rgba_binary}`.
  """
  def decode_image(type, buffer) when type in [:webp, :png] do
    dir = tmp_dir()

    try do
      %{"width" => width, "height" => height, "data" => data} = node!(@decode_js, [type, write!(dir, "image", buffer)])
      %{width: width, height: height, data: Base.decode64!(data)}
    after
      File.rm_rf!(dir)
    end
  end

  @doc """
  `utils.compare(image1.data, image2.data, null, image1.width, image2.height)` of two PNG buffers
  (`PNG.sync.read`), as upstream's specs call it: the number of different pixels.
  """
  def compare(png1, png2) do
    dir = tmp_dir()

    try do
      node!(@count_js, [write!(dir, "image1", png1), write!(dir, "image2", png2)])
    after
      File.rm_rf!(dir)
    end
  end

  # utils/fileUtils.ts sanitizeForFilePath
  defp sanitize_for_file_path(s), do: String.replace(s, ~r/[\x00-\x2C\x2E-\x2F\x3A-\x40\x5B-\x60\x7B-\x7F]+/, "-")

  defp mime_type(".png"), do: "image/png"
  defp mime_type(".jpg"), do: "image/jpeg"
  defp mime_type(".jpeg"), do: "image/jpeg"
  defp mime_type(".webp"), do: "image/webp"

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "playwright_ex-snapshot-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  defp write!(dir, name, buffer) do
    path = Path.join(dir, name)
    File.write!(path, buffer)
    path
  end

  # Runs `script` with `args`, `fs`, the driver package's `utils` (`lib/coreBundle.js`), the
  # `utilsBundle` path and `out(value)` (prints JSON) in scope; returns the decoded output.
  defp node!(script, args) do
    {node, [cli | _]} = PlaywrightEx.Driver.executable()
    lib = Path.join(Path.dirname(cli), "lib")

    prelude = """
    const fs = require('fs');
    const [coreBundle, utilsBundle, ...args] = process.argv.slice(1);
    const { utils } = require(coreBundle);
    const out = value => process.stdout.write(JSON.stringify(value));
    """

    argv = [Path.join(lib, "coreBundle.js"), Path.join(lib, "utilsBundle.js") | Enum.map(args, &to_string/1)]
    {output, 0} = System.cmd(node, ["-e", prelude <> script | argv])
    JSON.decode!(output)
  end
end
