defmodule PlaywrightEx.Library.BrowsercontextWebauthnTest do
  @upstream "tests/library/browsercontext-webauthn.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  import Bitwise

  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Credentials
  alias PlaywrightEx.Page

  # Runs an assertion ceremony with a discoverable credential, returns the signature counter from the authenticator data.
  defp assert_and_get_sign_count(page, rp_id) do
    Page.evaluate!(
      page,
      """
      async ({ rpId }) => {
        const challenge = crypto.getRandomValues(new Uint8Array(32));
        const cred = await navigator.credentials.get({
          publicKey: { challenge, rpId, userVerification: 'preferred' },
        });
        const resp = cred.response;
        return new DataView(resp.authenticatorData).getUint32(33);
      }
      """,
      %{rpId: rp_id}
    )
  end

  # JS passes a credential (`known`) as the options of `create`: here its fields are the options.
  defp credential_options(credential) do
    [
      id: credential.id,
      user_handle: credential.userHandle,
      private_key: credential.privateKey,
      public_key: credential.publicKey,
      sign_count: credential.signCount
    ]
  end

  @b64_url_to_bytes """
  const b64UrlToBytes = (s) => {
    let str = s.replace(/-/g, '+').replace(/_/g, '/');
    while (str.length % 4)
      str += '=';
    const bin = atob(str);
    const u8 = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++)
      u8[i] = bin.charCodeAt(i);
    return u8;
  };
  """

  @create_credential """
  async ({ rpId }) => {
    const challenge = crypto.getRandomValues(new Uint8Array(32));
    const created = await navigator.credentials.create({
      publicKey: {
        challenge,
        rp: { id: rpId, name: 'Test RP' },
        user: { id: new Uint8Array([1, 2, 3, 4]), name: 'u', displayName: 'User' },
        pubKeyCredParams: [{ type: 'public-key', alg: -7 }],
        authenticatorSelection: { residentKey: 'required', userVerification: 'preferred' },
      },
    });
    return created.id;
  }
  """

  @get_discoverable_credential """
  async ({ rpId }) => {
    const challenge = crypto.getRandomValues(new Uint8Array(32));
    // No allowCredentials — relies on the re-seeded credential being discoverable.
    const cred = await navigator.credentials.get({
      publicKey: { challenge, rpId, userVerification: 'preferred' },
    });
    return cred.id;
  }
  """

  test "should not intercept navigator.credentials without install()", %{
    context_factory: context_factory,
    server: server
  } do
    context = context_factory.([])
    # Seed a credential, but do not install the interceptor.
    Credentials.create!(BrowserContext.credentials(context), server.hostname)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)

    intercepted = Page.evaluate!(page, "() => globalThis.__pwWebAuthnInstalled === true")
    assert intercepted == false
  end

  test "should seed a known credential and authenticate", %{context_factory: context_factory, server: server} do
    # This is the easiest way to create credentials. In practice, this
    # probably comes from environment.
    source = context_factory.([])
    known = Credentials.create!(BrowserContext.credentials(source), server.hostname)

    # A fresh context imports the known credential and signs in with it.
    context = context_factory.([])
    Credentials.create!(BrowserContext.credentials(context), known.rpId, credential_options(known))
    Credentials.install!(BrowserContext.credentials(context))
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)

    result =
      Page.evaluate!(
        page,
        """
        async ({ rpId, credentialId }) => {
          #{@b64_url_to_bytes}
          const challenge = crypto.getRandomValues(new Uint8Array(32));
          const cred = await navigator.credentials.get({
            publicKey: {
              challenge,
              rpId,
              allowCredentials: [{ type: 'public-key', id: b64UrlToBytes(credentialId) }],
              userVerification: 'preferred',
            },
          });
          const resp = cred.response;
          return {
            id: cred.id,
            type: cred.type,
            hasClientData: resp.clientDataJSON.byteLength > 0,
            hasAuthData: resp.authenticatorData.byteLength > 0,
            hasSignature: resp.signature.byteLength > 0,
            authDataFlags: new Uint8Array(resp.authenticatorData)[32],
          };
        }
        """,
        %{rpId: server.hostname, credentialId: known.id}
      )

    assert result["id"] == known.id
    assert result["type"] == "public-key"
    assert result["hasClientData"] == true
    assert result["hasAuthData"] == true
    assert result["hasSignature"] == true
    # UP (0x01) | UV (0x04) = 0x05
    assert (result["authDataFlags"] &&& 0x05) == 0x05

    # After the credential is deleted, the page can no longer authenticate with it.
    Credentials.delete!(BrowserContext.credentials(context), known.id)
    assert Credentials.get!(BrowserContext.credentials(context)) == []

    error =
      Page.evaluate!(
        page,
        """
        async ({ rpId, credentialId }) => {
          #{@b64_url_to_bytes}
          const challenge = crypto.getRandomValues(new Uint8Array(32));
          try {
            await navigator.credentials.get({
              publicKey: {
                challenge,
                rpId,
                allowCredentials: [{ type: 'public-key', id: b64UrlToBytes(credentialId) }],
              },
            });
            return 'no-error';
          } catch (e) {
            return e.name;
          }
        }
        """,
        %{rpId: server.hostname, credentialId: known.id}
      )

    assert error == "NotAllowedError"
  end

  test "should capture a page-created credential and reuse it in another context", %{
    context_factory: context_factory,
    server: server
  } do
    # Setup context: the app registers a passkey via navigator.credentials.create().
    setup_context = context_factory.([])
    Credentials.install!(BrowserContext.credentials(setup_context))
    setup_page = BrowserContext.new_page!(setup_context)
    Page.goto!(setup_page, server.empty_page)

    created_id = Page.evaluate!(setup_page, @create_credential, %{rpId: server.hostname})

    [captured] = Credentials.get!(BrowserContext.credentials(setup_context), rp_id: server.hostname)
    assert captured.id == created_id
    assert captured.privateKey =~ ~r/^[A-Za-z0-9_-]+$/
    assert captured.publicKey =~ ~r/^[A-Za-z0-9_-]+$/

    # Reuse the captured passkey in a fresh context and sign in with it.
    context = context_factory.([])
    Credentials.create!(BrowserContext.credentials(context), captured.rpId, credential_options(captured))
    Credentials.install!(BrowserContext.credentials(context))
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)

    got_id = Page.evaluate!(page, @get_discoverable_credential, %{rpId: server.hostname})

    assert got_id == created_id
  end

  @tag skip: "not ported: BrowserContext.storageState"
  test "should reuse a page-created credential via the storageState option"

  test "should seed and report signCount", %{context_factory: context_factory, server: server} do
    context = context_factory.([])
    fresh = Credentials.create!(BrowserContext.credentials(context), "fresh.example.com")
    assert fresh.signCount == 0

    seeded = Credentials.create!(BrowserContext.credentials(context), server.hostname, sign_count: 41)
    assert seeded.signCount == 41
    Credentials.install!(BrowserContext.credentials(context))
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)

    # Each assertion increments the counter and reports the new value to the page.
    assert assert_and_get_sign_count(page, server.hostname) == 42
    assert assert_and_get_sign_count(page, server.hostname) == 43
    assert Credentials.get!(BrowserContext.credentials(context), id: seeded.id) == [%{seeded | signCount: 43}]
    assert Credentials.get!(BrowserContext.credentials(context), id: fresh.id) == [fresh]

    # A captured credential continues from the same counter in another context.
    [captured] = Credentials.get!(BrowserContext.credentials(context), id: seeded.id)
    context2 = context_factory.([])
    Credentials.create!(BrowserContext.credentials(context2), captured.rpId, credential_options(captured))
    Credentials.install!(BrowserContext.credentials(context2))
    page2 = BrowserContext.new_page!(context2)
    Page.goto!(page2, server.empty_page)
    assert assert_and_get_sign_count(page2, server.hostname) == 44
  end

  test "should reject invalid signCount", %{context_factory: context_factory} do
    context = context_factory.([])
    {:error, error} = Credentials.create(BrowserContext.credentials(context), "example.com", sign_count: -1)
    assert Exception.message(error) =~ "signCount must be between 0 and 4294967295, got -1"
    assert Credentials.get!(BrowserContext.credentials(context)) == []
  end

  @tag skip: "not ported: BrowserContext.storageState"
  test "should preserve signCount via the storageState option"

  test "should serialize credentials with toJSON", %{context_factory: context_factory, server: server} do
    context = context_factory.([])
    Credentials.install!(BrowserContext.credentials(context))
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)

    %{"registration" => registration, "authentication" => authentication, "expected" => expected} =
      Page.evaluate!(
        page,
        """
        async ({ rpId }) => {
          const toB64Url = (buf) => btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\\+/g, '-').replace(/\\//g, '_').replace(/=+$/, '');
          const created = await navigator.credentials.create({
            publicKey: {
              challenge: crypto.getRandomValues(new Uint8Array(32)),
              rp: { id: rpId, name: 'Test RP' },
              user: { id: new Uint8Array([1, 2, 3, 4]), name: 'u', displayName: 'User' },
              pubKeyCredParams: [{ type: 'public-key', alg: -7 }],
              authenticatorSelection: { residentKey: 'required' },
            },
          });
          const attestation = created.response;
          const got = await navigator.credentials.get({
            publicKey: { challenge: crypto.getRandomValues(new Uint8Array(32)), rpId },
          });
          const assertion = got.response;
          return {
            registration: JSON.parse(JSON.stringify(created)),
            authentication: JSON.parse(JSON.stringify(got)),
            expected: {
              id: created.id,
              attestation: {
                clientDataJSON: toB64Url(attestation.clientDataJSON),
                authenticatorData: toB64Url(attestation.getAuthenticatorData()),
                publicKey: toB64Url(attestation.getPublicKey()),
                attestationObject: toB64Url(attestation.attestationObject),
              },
              assertion: {
                clientDataJSON: toB64Url(assertion.clientDataJSON),
                authenticatorData: toB64Url(assertion.authenticatorData),
                signature: toB64Url(assertion.signature),
                userHandle: toB64Url(assertion.userHandle),
              },
            },
          };
        }
        """,
        %{rpId: server.hostname}
      )

    assert registration == %{
             "id" => expected["id"],
             "rawId" => expected["id"],
             "response" =>
               Map.merge(expected["attestation"], %{"transports" => ["internal"], "publicKeyAlgorithm" => -7}),
             "authenticatorAttachment" => "platform",
             "clientExtensionResults" => %{},
             "type" => "public-key"
           }

    assert authentication == %{
             "id" => expected["id"],
             "rawId" => expected["id"],
             "response" => expected["assertion"],
             "authenticatorAttachment" => "platform",
             "clientExtensionResults" => %{},
             "type" => "public-key"
           }

    [credential] = Credentials.get!(BrowserContext.credentials(context))
    assert registration["response"]["publicKey"] == credential.publicKey
    assert authentication["response"]["userHandle"] == credential.userHandle

    assert JSON.decode!(Base.url_decode64!(registration["response"]["clientDataJSON"], padding: false))["type"] ==
             "webauthn.create"

    assert JSON.decode!(Base.url_decode64!(authentication["response"]["clientDataJSON"], padding: false))["type"] ==
             "webauthn.get"

    # Registration authenticator data is embedded in the attestation object and carries attested credential data (AT flag).
    auth_data = Base.url_decode64!(registration["response"]["authenticatorData"], padding: false)

    assert :binary.match(Base.url_decode64!(registration["response"]["attestationObject"], padding: false), auth_data) !=
             :nomatch

    assert (:binary.at(auth_data, 32) &&& 0x40) == 0x40
  end
end
