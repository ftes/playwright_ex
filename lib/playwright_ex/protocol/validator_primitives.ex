defmodule PlaywrightEx.Protocol.ValidatorPrimitives do
  @upstream "packages/protocol/src/validatorPrimitives.ts"
  @moduledoc """
  Port of `#{@upstream}`.

  Upstream composes validator functions (`tObject({ url: tString, ... })`); the generated
  `PlaywrightEx.Protocol.Validator.scheme/1` returns the same schemes as data, which
  `validate/4` interprets:

      :float | :int | :boolean | :string | :binary | :undefined | :any
      {:optional, s} | {:array, s} | {:object, [key: s, ...]} | {:enum, [literal]}
      {:channel, :* | [type]} | {:type, name}

  Elixir specifics: `nil` is `undefined`. `{:object, ...}` reads atom or string keys (wire
  JSON keeps string keys) and returns atom keys, dropping `nil` values as upstream drops
  `undefined`. `:binary` in a `"toBase64"` context takes any binary.

  The context mirrors `ValidatorContext`: `%{tChannelImpl: fun/4, binary: "toBase64" | "fromBase64" | "buffer",
  isUnderTest: fun/0}` (`isUnderTest` may be missing: not under test).
  """
  alias PlaywrightEx.Protocol.Validator

  defmodule ValidationError do
    @moduledoc false
    defexception [:message]
  end

  def find_validator(type, method, kind) do
    maybe_find_validator(type, method, kind) ||
      raise ValidationError, message: "Unknown scheme for #{kind}: #{type}.#{method}"
  end

  def maybe_find_validator(type, method, kind) do
    scheme_name = type <> if(kind == "Initializer", do: "", else: upcase_first(to_string(method))) <> kind
    if scheme = Validator.scheme(scheme_name), do: validator(scheme)
  end

  def create_metadata_validator, do: validator({:optional, {:type, "Metadata"}})

  def create_wait_info_validator, do: validator({:type, "WaitInfo"})

  defp validator(scheme), do: fn arg, path, context -> validate(scheme, arg, path, context) end

  @doc "Validates and converts `arg` against `scheme` (the composed validator call upstream)."
  def validate(:float, arg, _path, _context) when is_number(arg), do: arg
  def validate(:float, arg, path, _context), do: fail("#{path}: expected float, got #{type_of(arg)}")

  def validate(:int, arg, _path, _context) when is_integer(arg), do: arg
  def validate(:int, arg, _path, _context) when is_float(arg) and arg == trunc(arg), do: arg
  def validate(:int, arg, path, _context) when is_float(arg), do: fail("#{path}: expected integer, got float #{arg}")
  def validate(:int, arg, path, _context), do: fail("#{path}: expected integer, got #{type_of(arg)}")

  def validate(:boolean, arg, _path, _context) when is_boolean(arg), do: arg
  def validate(:boolean, arg, path, _context), do: fail("#{path}: expected boolean, got #{type_of(arg)}")

  def validate(:string, arg, _path, _context) when is_binary(arg), do: arg
  def validate(:string, arg, path, _context), do: fail("#{path}: expected string, got #{type_of(arg)}")

  def validate(:binary, arg, path, %{binary: "fromBase64"}) do
    with true <- is_binary(arg), {:ok, decoded} <- Base.decode64(arg) do
      decoded
    else
      _ -> fail("#{path}: expected base64-encoded buffer, got #{type_of(arg)}")
    end
  end

  def validate(:binary, arg, _path, %{binary: "toBase64"}) when is_binary(arg), do: Base.encode64(arg)
  def validate(:binary, arg, path, %{binary: "toBase64"}), do: fail("#{path}: expected Buffer, got #{type_of(arg)}")
  def validate(:binary, arg, _path, %{binary: "buffer"}), do: arg
  def validate(:binary, _arg, _path, %{binary: binary}), do: fail(~s(Unsupported binary behavior "#{binary}"))

  def validate(:undefined, nil, _path, _context), do: nil
  def validate(:undefined, arg, path, _context), do: fail("#{path}: expected undefined, got #{type_of(arg)}")

  def validate(:any, arg, _path, _context), do: arg

  def validate({:optional, _scheme}, nil, _path, _context), do: nil
  def validate({:optional, scheme}, arg, path, context), do: validate(scheme, arg, path, context)

  def validate({:array, scheme}, arg, path, context) when is_list(arg),
    do: arg |> Enum.with_index() |> Enum.map(fn {x, index} -> validate(scheme, x, "#{path}[#{index}]", context) end)

  def validate({:array, _scheme}, arg, path, _context), do: fail("#{path}: expected array, got #{type_of(arg)}")

  # Not a `for` with `value = validate(...)` as a filter: a falsy match filters, so `false` would be dropped.
  def validate({:object, schemes}, arg, path, context) when is_map(arg) do
    result =
      Enum.reduce(schemes, %{}, fn {key, scheme}, result ->
        case validate(scheme, fetch(arg, key), if(path == "", do: "#{key}", else: "#{path}.#{key}"), context) do
          nil -> result
          value -> Map.put(result, key, value)
        end
      end)

    if context[:isUnderTest] && context.isUnderTest.() do
      for {key, value} <- Map.to_list(arg),
          String.starts_with?(to_string(key), "__testHook"),
          into: result,
          do: {key, value}
    else
      result
    end
  end

  def validate({:object, _schemes}, :null, path, _context), do: fail("#{path}: expected object, got null")
  def validate({:object, _schemes}, arg, path, _context), do: fail("#{path}: expected object, got #{type_of(arg)}")

  def validate({:enum, literals}, arg, path, _context) do
    if arg in literals, do: arg, else: fail("#{path}: expected one of (#{Enum.join(literals, "|")})")
  end

  def validate({:channel, names}, arg, path, context), do: context.tChannelImpl.(names, arg, path, context)

  def validate({:type, name}, arg, path, context) do
    case Validator.scheme(name) do
      nil -> fail(~s(#{path}: unknown type "#{name}"))
      scheme -> validate(scheme, arg, path, context)
    end
  end

  defp fetch(arg, key) do
    case arg do
      %{^key => value} -> value
      _ -> Map.get(arg, Atom.to_string(key))
    end
  end

  defp fail(message), do: raise(ValidationError, message: message)

  # JS `typeof`
  defp type_of(nil), do: "undefined"
  defp type_of(arg) when is_boolean(arg), do: "boolean"
  defp type_of(arg) when is_number(arg), do: "number"
  defp type_of(arg) when is_binary(arg), do: "string"
  defp type_of(arg) when is_function(arg), do: "function"
  defp type_of(_arg), do: "object"

  defp upcase_first(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest
end
