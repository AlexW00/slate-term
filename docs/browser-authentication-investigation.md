# Browser passwords, popups, OAuth, and passkeys

Investigation date: 2026-10-20. Source revision: `08d08f0a33477c581e449ddf26ad97103b9e32d9`.

Historical snapshot: popup handling described here was superseded by the browser integration shipped in 0.8.0. The findings below describe the recorded source revision, not the current popup implementation. Password AutoFill, passkey entitlement eligibility, and live provider compatibility remain separate questions.

Status at investigation time: findings only. No fixes, prototypes, entitlement requests, or authentication attempts were made. Follow-up work below is proposed, not implemented.

## Findings

| Feature | Current assessment |
| --- | --- |
| Safari-style Apple Passwords suggestions | No dedicated integration. A public route to equivalent behavior across arbitrary websites was not established. |
| New-window links and authentication popups | Requests reuse the existing pane. Flows requiring a child window can break. |
| OAuth through ordinary page redirects | No blanket prohibition in Slate, but compatibility depends on the provider and callback. Not live-tested. |
| OAuth providers rejecting embedded browsers | Can fail independently of popup handling. Google documents this restriction. |
| Apple Passwords/iCloud passkeys across arbitrary websites | The installed app lacks Apple's managed browser passkey entitlement. |

The investigation inspected source, local SDK headers, the installed app's code-signing entitlements, and Apple/Google documentation. It did not establish runtime authentication compatibility.

## Current implementation

- [`Native/BrowserPane.swift`](../Native/BrowserPane.swift): `BrowserPane` is an AppKit controller using `WKWebView`. Its initializer sets the website data store and navigation/UI delegates.
- `webView(_:createWebViewWith:for:windowFeatures:)` loads an allowed popup request into the existing web view and returns `nil`. It does not create a child view using the supplied configuration.
- There is no `webViewDidClose` handler or `ASWebAuthenticationSession` integration in the inspected browser implementation.
- [`Sources/SlateTermCore/BrowserURL.swift`](../Sources/SlateTermCore/BrowserURL.swift): navigation permits HTTP, HTTPS, approved local file URLs, and `about:blank`. Custom-scheme app callbacks are rejected.
- [`Native/BrowserData.swift`](../Native/BrowserData.swift): ordinary browser panes share a named persistent profile per application state directory. Each private pane receives a fresh ephemeral store. These are separate from Safari's session.
- [`AppInfo.plist`](../AppInfo.plist) registers `slate-term` for saved layouts, not HTTP/HTTPS browser handling.
- Reading `/Applications/Slate Terminal.app` with `codesign -d --entitlements :-` produced no entitlement payload. In particular, no browser passkey entitlement was present. This observation applies to that installed copy at investigation time.
- [`Tests/WebOperations/BrowserNavigation.swift`](../Tests/WebOperations/BrowserNavigation.swift) checks that a local `target="_blank"` link replaces the current document. This is coverage for the existing behavior, not opener messaging or OAuth compatibility. The test was inspected, not rerun.

## Apple Passwords and password AutoFill

Using `WKWebView` does not by itself establish Safari-equivalent password suggestions, saving, or generation in an AppKit browser.

Apple's documented app password-sharing APIs use an associated-domain relationship, including cooperation from the website owner and user consent. That can support an app's own service, but does not provide a general solution for arbitrary websites visited in Slate. Apple's platform-security documentation specifically describes automatic credential dropdowns on Mac for Mac Catalyst apps; Slate uses AppKit.

No public API was established in this investigation that simply enables Safari's Apple Passwords popup throughout Slate. This is an unresolved feasibility question, not proof that every form of password filling is impossible. Manual system filling UI, automatic suggestions, saving, and generation must be evaluated separately.

The browser passkey entitlement discussed below does not, by itself, establish ordinary password AutoFill support. The SDK's autofill scripting facilities likewise do not establish access to Apple Passwords.

References:

- [App access to saved passwords](https://support.apple.com/guide/security/app-access-to-saved-passwords-sec8762eb992/web)
- [Password AutoFill security](https://support.apple.com/guide/security/password-autofill-security-sec7aefe77c3/web)
- [Password AutoFill](https://developer.apple.com/documentation/security/password-autofill)

## Popups and OAuth

The current popup implementation can navigate to a simple link's destination. It cannot preserve a separate child browsing context for flows that expect the original page to stay open, communicate through `window.opener` or `postMessage`, or close the child after authentication. This is an inference from the implementation, not a reproduced provider-specific failure.

A prospective fix would create and retain a child `WKWebView` using WebKit's supplied configuration, display it with an identifiable origin, and handle `webViewDidClose`. It must preserve the parent/child relationship and session store. In particular, a private popup must share its parent's ephemeral store; creating an unrelated private pane would lose that session relationship. Popup admission, user cancellation, and parent closure also need defined behavior.

OAuth has additional limits:

- Ordinary HTTP/HTTPS redirect flows may work in the current pane, subject to provider policy and cookie behavior.
- Google documents `disallowed_useragent` errors for authorization in `WKWebView`. Correct child-window handling does not remove that provider restriction.
- Custom-scheme callbacks currently fail Slate's navigation policy. External-app handoff needs deliberate handling.
- For authentication initiated and owned by a native app, Apple recommends `ASWebAuthenticationSession`. Slate has no such integration.
- That session API is not a universal replacement for arbitrary website login popups. An external-browser fallback also does not automatically transfer the resulting login into Slate's separate cookie store.

References:

- [WKUIDelegate](https://developer.apple.com/documentation/webkit/wkuidelegate)
- [Google OAuth embedded-user-agent policy](https://developers.google.com/identity/protocols/oauth2/policies)
- [Google OAuth: disallowed_useragent](https://developers.google.com/identity/protocols/oauth2/javascript-implicit-flow#disallowed_useragent)
- [ASWebAuthenticationSession](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession)

## Passkeys

Apple documents two relevant routes:

1. An ordinary app can use passkeys for its associated websites.
2. A qualifying browser can request `com.apple.developer.web-browser.public-key-credential` to make registration and assertion requests for arbitrary relying parties.

The second route is relevant to Slate's general browsing capability. Apple's published requirements include an application by the Account Holder of an organization developer account, HTTP/HTTPS scheme registration, browser functionality, and Apple review. Slate's eligibility and approval are unconfirmed; adding a signing key locally would not substitute for approval and provisioning.

Apple documents WebKit handling website WebAuthn challenges for `WKWebView` browsers. Browser access to a user's passkeys also involves user authorization, with `ASAuthorizationWebBrowserPublicKeyCredentialManager` available to inspect/request access.

The missing entitlement means browser-wide access to local Apple Passwords/iCloud passkeys is not configured. This does not prove every WebAuthn path fails: external security keys and cross-device flows were not tested and must not be described as either supported or unsupported from this evidence.

References:

- [Browser public-key credential entitlement and eligibility](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.web-browser.public-key-credential)
- [Passkey use in web browsers](https://developer.apple.com/documentation/authenticationservices/passkey-use-in-web-browsers)
- [Supporting passkeys in apps and web views](https://developer.apple.com/documentation/authenticationservices/supporting-passkeys)
- [Browser passkey authorization manager](https://developer.apple.com/documentation/authenticationservices/asauthorizationwebbrowserpublickeycredentialmanager)

## Deferred follow-up and acceptance evidence

Recommended order if implementation is authorized later:

1. Fix popup lifecycle using a controlled fixture. Verify the parent remains open, opener messaging reaches it, child closure works, and normal/private session boundaries hold.
2. Establish browser passkey entitlement eligibility and signing requirements. After approval and implementation, verify registration, assertion, permission denial, and cancellation on a suitable Mac.
3. Run a small AppKit password AutoFill feasibility probe. Distinguish a manual credential picker from automatic site suggestions, and test saving/generation separately.
4. Check representative real OAuth providers, same-window and popup flows, custom-scheme handoff, and external-browser fallback. Keep provider restrictions distinct from Slate defects.

No live credentials, Touch ID dialogs, password suggestions, passkey registration/assertion, OAuth providers, security keys, or cross-device authentication were exercised. No build or test-suite pass is claimed. Future native probes must follow the repository's VM-testing rules; a physical-Mac test needs separate host-GUI authorization.
