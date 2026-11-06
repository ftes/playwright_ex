defmodule PlaywrightEx.Examples.CredentialsTest do
  # Elixir translations of upstream's JS examples, rendered into the facade docs (see ExampleCase).
  use PlaywrightEx.ExampleCase, async: true

  alias PlaywrightEx.Credentials

  @register ~S"""
  <button onclick="register()">Create a passkey</button>
  <script>
    async function register() {
      await navigator.credentials.create({
        publicKey: {
          challenge: crypto.getRandomValues(new Uint8Array(32)),
          rp: { id: 'example.com', name: 'Example' },
          user: { id: new Uint8Array([1, 2, 3, 4]), name: 'john', displayName: 'John' },
          pubKeyCredParams: [{ type: 'public-key', alg: -7 }],
          authenticatorSelection: { residentKey: 'required' },
        },
      });
    }
  </script>
  """

  # The examples keep the passkey in playwright/.auth, removed after each test.
  setup do
    if !File.exists?("playwright"), do: on_exit(fn -> File.rm_rf!("playwright") end)
    File.mkdir_p!("playwright/.auth")
    :ok
  end

  example "Credentials",
    js: ~S"""
    const context = await browser.newContext();

    // A passkey your backend already provisioned for a test user.
    await context.credentials.create('example.com', {
      id: knownCredentialId, // base64url
      userHandle: knownUserHandle, // base64url
      privateKey: knownPrivateKey, // base64url PKCS#8 (DER)
      publicKey: knownPublicKey, // base64url SPKI (DER)
    });
    await context.credentials.install();

    const page = await context.newPage();
    await page.goto('https://example.com/login');
    // The page's navigator.credentials.get() is answered with the seeded passkey.
    """,
    given: [
      known: BrowserContext.credentials(context) |> Credentials.create!("example.com"),
      known_credential_id: known.id,
      known_user_handle: known.userHandle,
      known_private_key: known.privateKey,
      known_public_key: known.publicKey
    ] do
    context = Browser.new_context!(browser)

    # A passkey your backend already provisioned for a test user.
    # All base64url: the private key PKCS#8 (DER), the public key SPKI (DER).
    BrowserContext.credentials(context)
    |> Credentials.create!("example.com",
      id: known_credential_id,
      user_handle: known_user_handle,
      private_key: known_private_key,
      public_key: known_public_key
    )

    BrowserContext.credentials(context) |> Credentials.install!()

    page = BrowserContext.new_page!(context)
    Page.goto!(page, "https://example.com/login")
    # The page's navigator.credentials.get() is answered with the seeded passkey.
  end

  example "Credentials",
    js: ~S"""
    // setup test: let the app register a passkey, then save the storage state with it.
    const context = await browser.newContext();
    await context.credentials.install();

    const page = await context.newPage();
    await page.goto('https://example.com/register');
    await page.getByRole('button', { name: 'Create a passkey' }).click();

    // Read back the passkey the page registered — it includes the private key.
    const [credential] = await context.credentials.get({ rpId: 'example.com' });
    fs.writeFileSync('playwright/.auth/passkey.json', JSON.stringify(credential));
    """,
    html: @register do
    # setup test: let the app register a passkey, then save the storage state with it.
    context = Browser.new_context!(browser)
    BrowserContext.credentials(context) |> Credentials.install!()

    page = BrowserContext.new_page!(context)
    Page.goto!(page, "https://example.com/register")
    Page.get_by_role(page, :button, name: "Create a passkey") |> Locator.click!()

    # Read back the passkey the page registered — it includes the private key.
    [credential] = BrowserContext.credentials(context) |> Credentials.get!(rp_id: "example.com")
    File.write!("playwright/.auth/passkey.json", JSON.encode!(credential))
  end

  example "Credentials",
    js: ~S"""
    // later test: seed the captured passkey so the app starts already enrolled.
    const credential = JSON.parse(fs.readFileSync('playwright/.auth/passkey.json', 'utf8'));
    const context = await browser.newContext();
    await context.credentials.create(credential.rpId, credential);
    await context.credentials.install();

    const page = await context.newPage();
    await page.goto('https://example.com/login');
    // navigator.credentials.get() resolves the captured passkey — already signed in.
    """,
    given: [_saved: save_passkey(context)] do
    # later test: seed the captured passkey so the app starts already enrolled.
    credential = File.read!("playwright/.auth/passkey.json") |> JSON.decode!()
    context = Browser.new_context!(browser)

    BrowserContext.credentials(context)
    |> Credentials.create!(credential["rpId"],
      id: credential["id"],
      user_handle: credential["userHandle"],
      private_key: credential["privateKey"],
      public_key: credential["publicKey"],
      sign_count: credential["signCount"]
    )

    BrowserContext.credentials(context) |> Credentials.install!()

    page = BrowserContext.new_page!(context)
    Page.goto!(page, "https://example.com/login")
    # navigator.credentials.get() resolves the captured passkey — already signed in.
  end

  # What the setup test above saves.
  defp save_passkey(context) do
    credential = BrowserContext.credentials(context) |> Credentials.create!("example.com")
    File.write!("playwright/.auth/passkey.json", JSON.encode!(credential))
  end
end
