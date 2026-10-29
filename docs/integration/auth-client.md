# AuthClient integration contract

`Core/Clients/AuthClient.swift` is the UI boundary. Replace the `auth` dependency at the composition root (`ChatCallApp` / `AppDependencies`); views and stores consume the protocol. The current app is an in-memory demonstration, not an identity implementation.

| Member | Required behavior | Cancellation and ordering |
|---|---|---|
| `currentSession` | Return the current authenticated identity, or nil. Mock sessions contain a user and sign-in date, no token. The current Login gate starts unauthenticated; startup restoration is not implemented. | The getter is async/nonthrowing. Define persistence/restore and expiry before using it for startup routing. Never expose a session invalidated by sign-out. |
| `signIn(credentials:)` | Accept a trimmed username/email and password. Return a validated session or a typed invalid-credentials failure. The UI requires a nonblank identity and at least six password characters; this is demo validation, not an identity policy. | Propagate task cancellation, cancel underlying network work, and check cancellation before committing session state. Latest attempt wins. A response arriving after sign-out must not restore authentication. Do not blindly retry a credential submission. |
| `signOut()` | Clear local session and revoke/close remote resources according to the future contract. It is nonthrowing. `AuthStore` cancels sign-in, clears password/drafts, resets routers/feature stores, then awaits sign-out before showing Login. | Invalidate in-flight sign-ins first; repeated sign-out must be safe. Cancellation must not prevent local credential removal. Define bounded remote revocation and offline policy without blocking local logout indefinitely. |

There is no auth event stream, refresh method, or token provider in this protocol. `AuthStore` uses revision guards in addition to cancellation; an adapter must not rely on UI guards to prevent stale credential persistence. Never log passwords, credentials, session tokens, or authorization headers.

## Live adapter

`LiveAuthClient` (`Core/Clients/LiveAuthClient.swift`) implements `POST {baseURL}/v1/token` with `{user_id, app_id, password}` and reads `{token, expires_at}`. 401/403 map to `invalidCredentials`; 429, 5xx, and transport failures map to `unavailable`; a malformed 200 maps to `invalidResponse`. The user id comes from the JWT `sub` claim (read unverified, display only). The session carries an `AccessToken` (redacted in logs) and is kept in the Keychain (`KeychainSessionStore`); expired sessions are dropped on read.

It is the default. `AuthConfiguration.dev` holds the dev URL and app id (the quick-tunnel URL changes on restart); override with `-authBaseURL`/`-authAppID`. `-demo-mock` or `-demo-immediateEvents` (all UI tests) selects the full mock. Chat and calls remain mocked, so the mock `user-me` identity still applies to them.

Since the live chat work: sign-in also sends a stable per-install `device_id` (the server signs it into the token's `dev` claim, and a token without one cannot register a push device). `LiveAuthClient` is an `AccessTokenProvider`: `validToken()` refreshes through `POST /v1/token/refresh` (old token as bearer) once the token is within 60 seconds of expiry, sharing a single in-flight refresh between callers. A refresh 401 whose body carries code 70009 (`ErrorCode` or `code`) is `AuthError.revoked`; any other 401 ends the session; 5xx keeps it and reports `.unavailable`.

Still open: a server-side logout/revocation endpoint (sign-out is local only), startup session restoration in `AuthStore`, and the call adapter's use of the token provider.

## Mock replacement checklist

- [ ] Supply identity service login, refresh, logout/revocation, expiry, error, and session-restoration contracts. No Login endpoint or wire shape has been supplied.
- [ ] Supply reachable environment URLs, test accounts, issuer/audience/app and user/device/session identity mappings through the team's configuration channel.
- [ ] Define secure token storage, refresh serialization, cancellation, logout/offline behavior, and account-switch cleanup.
- [x] Token provider below the UI boundary (`AccessTokenProvider`, used by the chat gateway and realtime socket). The call adapter will reuse it; the VoIP handoff consumes an existing identity JWT and does not provide login/refresh.
- [ ] Replace mock `user-me` identity assumptions in composition/domain consumers with the authenticated user when implementing live integration.
- [ ] Exercise invalid credentials, offline/expiry, cancellation, concurrent sign-in/sign-out, and relaunch on the real adapter before enabling restoration.

Keep secrets out of source, screenshots, logs, and this handoff. See [CallClient](call-client.md) for the supplied VoIP reference and [ChatClient](chat-client.md) for the missing chat contract.
