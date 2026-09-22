# Android release preparation

Sharemarium Android uses the production application ID and namespace:

- `com.futureatlas.sharemarium`

## Signing policy

Release builds must never use the debug keystore.

The repository intentionally does not contain the production upload keystore or
`android/key.properties`. When Android distribution is enabled:

1. Create a dedicated upload keystore outside Git.
2. Copy `android/key.properties.example` to `android/key.properties`.
3. Fill in `storePassword`, `keyPassword`, `keyAlias`, and `storeFile`.
4. Put the referenced keystore under `android/` or another protected local/CI path.
5. Verify the SHA-1/SHA-256 certificate fingerprints before configuring OAuth,
   Firebase, deep links, or Google Play.
6. Build the release artifact with `flutter build appbundle --release`.
7. Confirm the resulting AAB is signed with the intended upload certificate.

Both `android/key.properties` and common keystore extensions are ignored by Git.

## CI / secret handling

Do not commit keystore bytes or passwords. For a future Android release workflow,
materialize the keystore from CI secrets at build time, write
`android/key.properties` only inside the runner, build, then let the runner be
discarded.

## External work still required before Play release

- Create the real upload key.
- Register the application in Google Play Console using
  `com.futureatlas.sharemarium`.
- If Firebase/Google OAuth are used, register this application ID and its release
  certificate fingerprints there.
- Verify deep links and other package-name-dependent integrations.
