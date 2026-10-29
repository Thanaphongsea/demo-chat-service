# AuthClient integration contract

`Core/Clients/AuthClient.swift` is the UI boundary. Replace the `auth` dependency at the composition root (`ChatCallApp` / `AppDependencies`); views and stores consume the protocol. The current app is an in-memory demonstration, not an identity implementation.

| Member | Required behavior | Cancellation and ordering |
|---|---|---|
| `currentSession` | Return the current authenticated identity, or nil. Mock sessions contain a user and sign-in date, no token. The current Login gate starts unauthenticated; startup restoration is not implemented. | The getter is async/nonthrowing. Define persistence/restore and expiry before using it for startup routing. Never expose a session invalidated by sign-out. |
| `signIn(credentials:)` | Accept a trimmed username/email and password. Return a validated session or a typed invalid-credentials failure. The UI requires a nonblank identity and at least six password characters; this is demo validation, not an identity policy. | Propagate task cancellation, cancel underlying network work, and check cancellation before committing session state. Latest attempt wins. A response arriving after sign-out must not restore authentication. Do not blindly retry a credential submission. |
| `signOut()` | Clear local session and revoke/close remote resources according to the future contract. It is nonthrowing. `AuthStore` cancels sign-in, clears password/drafts, resets routers/feature stores, then awaits sign-out before showing Login. | Invalidate in-flight sign-ins first; repeated sign-out must be safe. Cancellation must not prevent local credential removal. Define bounded remote revocation and offline policy without blocking local logout indefinitely. |

There is no auth event stream, refresh method, or token provider in this protocol. `AuthStore` uses revision guards in addition to cancellation; an adapter must not rely on UI guards to prevent stale credential persistence. Never log passwords, credentials, session tokens, or authorization headers.

## Mock replacement checklist

- [ ] Supply identity service login, refresh, logout/revocation, expiry, error, and session-restoration contracts. No Login endpoint or wire shape has been supplied.
- [ ] Supply reachable environment URLs, test accounts, issuer/audience/app and user/device/session identity mappings through the team's configuration channel.
- [ ] Define secure token storage, refresh serialization, cancellation, logout/offline behavior, and account-switch cleanup.
- [ ] Add a token provider below the UI boundary for the call adapter; the VoIP handoff consumes an existing identity JWT and does not provide login/refresh.
- [ ] Replace mock `user-me` identity assumptions in composition/domain consumers with the authenticated user when implementing live integration.
- [ ] Exercise invalid credentials, offline/expiry, cancellation, concurrent sign-in/sign-out, and relaunch on the real adapter before enabling restoration.

Keep secrets out of source, screenshots, logs, and this handoff. See [CallClient](call-client.md) for the supplied VoIP reference and [ChatClient](chat-client.md) for the missing chat contract.
