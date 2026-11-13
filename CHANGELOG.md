# Changelog

## 0.1.0 (unreleased)

- First release: `AyInbox.new/1`, `AyInbox.Me`, `AyInbox.Campaigns` (list, stream, get, create, pause), `AyInbox.Contacts` (list, stream, get, create, update, delete), `AyInbox.Mailboxes` (list, stream), `AyInbox.Unibox` (list_threads, stream_threads, get_thread).
- `AyInbox.request/4` for any route and `AyInbox.paginate/3` for any paginated route.
- `AyInbox.Error` with a `type` per error category, retries on 429, 502, 503 and 504 that honour `Retry-After`, and per-call idempotency keys.
- `AyInbox.Webhooks.verify_signature/4` and `construct_event/4`.
