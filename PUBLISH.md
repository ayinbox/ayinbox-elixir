# Publishing to Hex

Hex has no trusted publishing (OIDC), so the release workflow uses an API key kept as a secret in a protected GitHub environment. Nothing is committed.

## One-time setup

1. Create the Hex account that will own the package, and turn on two-factor auth:
   `mix hex.user register` (or sign up at https://hex.pm), then enable 2FA at https://hex.pm/dashboard/security.
2. Check the name is free: https://hex.pm/packages/ayinbox should be a 404. The first publish claims it for that account.
3. Create an API key with write access to packages only:
   `mix hex.user key generate --key-name ayinbox-elixir-ci --permission api:write`
   (or Dashboard, Keys, "Generate", with the `api:write` permission). Copy the key once.
4. In GitHub, `ayinbox/ayinbox-elixir`, Settings, Environments, create an environment named `hex`. Add required reviewers and restrict deployment to tags matching `v*`.
5. In that environment, add the secret `HEX_API_KEY` with the key from step 3.
6. Optional: add other maintainers after the first publish with `mix hex.owner add ayinbox <email>`.

## Each release

1. Set `@version` in `mix.exs` and `@version` in `lib/ay_inbox/client.ex` to the new version, and move the `CHANGELOG.md` entry out of "unreleased".
2. Update the README install section to `{:ayinbox, "~> X.Y"}` once the package is on Hex.
3. Commit, then tag and push:

```sh
git tag v0.1.0
git push origin v0.1.0
```

`.github/workflows/release.yml` checks that the tag matches `mix.exs`, runs the tests, then runs `mix hex.publish --yes` (package and docs) in the `hex` environment.

To revert a bad release within an hour of publishing: `mix hex.publish --revert 0.1.0`. After that, retire it instead: `mix hex.retire ayinbox 0.1.0 invalid --message "..."`.
