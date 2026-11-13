# AY Inbox for Elixir

The official Elixir client for the AY Inbox REST API (`https://api.ayinbox.com/v1`). AY Inbox is a hosted cold email platform: it sends cold email at a paced daily volume, brings every reply into one inbox (Unibox), drafts answers from a per-campaign brain, and can offer a meeting time from Cal.com or Calendly.

AY Inbox is a hosted service. This repository holds the Elixir client for its public API. The service itself is not open source.

Access to the hosted service is invite only for now: ask at team@ayinbox.com.

## Install

Not on Hex yet. Install from GitHub in `mix.exs`:

```elixir
def deps do
  [
    {:ayinbox, github: "ayinbox/ayinbox-elixir"}
  ]
end
```

Requires Elixir 1.15 or later on OTP 26 or later. It uses [Req](https://hex.pm/packages/req) for HTTP.

## Quick start

```elixir
# Reads AYINBOX_API_KEY (an aybox_ key or an ayat_ OAuth token).
client = AyInbox.new()

{:ok, me} = AyInbox.Me.get(client)
IO.puts("Signed in as #{me["email"]} with #{Enum.join(me["scopes"], ", ")}")

client
|> AyInbox.Campaigns.stream(%{status: "active"})
|> Enum.each(fn c -> IO.puts("#{c["name"]}: #{c["status"]}") end)

contact = %{email: "lee@example.com", first_name: "Lee", company: "Example Co"}

case AyInbox.Contacts.create(client, contact, idempotency_key: "import-lee-2026-11-13") do
  {:ok, [created]} ->
    IO.puts("Saved contact #{created["id"]}")

  {:error, %AyInbox.Error{type: :permission_denied, code: code}} ->
    IO.puts("This key cannot write contacts (#{code})")

  {:error, error} ->
    IO.puts("Failed: #{Exception.message(error)}")
end
```

## Resources

Every function takes the client first and a keyword list of per-call options last. Results are the decoded JSON with string keys, so fields the API adds later are kept.

| Module | Functions | Route |
|---|---|---|
| `AyInbox.Me` | `get` | `GET /me` |
| `AyInbox.Campaigns` | `list`, `stream` | `GET /campaigns` |
| | `get` | `GET /campaigns/{id}` |
| | `create` | `POST /campaigns` |
| | `pause` | `POST /campaigns/{id}/stop` |
| `AyInbox.Contacts` | `list`, `stream` | `POST /contacts/search` |
| | `get` | `GET /contacts/{id}` |
| | `create` | `POST /contacts` (one map or a list; always returns a list) |
| | `update` | `PATCH /contacts/{id}` |
| | `delete` | `DELETE /contacts/{id}` |
| `AyInbox.Mailboxes` | `list`, `stream` | `GET /emails` |
| `AyInbox.Unibox` | `list_threads`, `stream_threads` | `GET /unibox` |
| | `get_thread` | `GET /unibox/thread` |
| `AyInbox.Webhooks` | `verify_signature`, `construct_event` | local, no HTTP |

Every other route is reachable through `AyInbox.request/4`, which uses the same auth, retries and error mapping:

```elixir
{:ok, overview} = AyInbox.request(client, :get, "/campaigns-overview")

{:ok, template} =
  AyInbox.request(client, :post, "/templates",
    body: %{name: "Follow-up", body_plain: "Thanks for the reply."},
    idempotency_key: "template-follow-up-1"
  )
```

## Configuration

```elixir
AyInbox.new(
  api_key: "aybox_...",                      # default: AYINBOX_API_KEY
  base_url: "https://api.ayinbox.com/v1",   # default: AYINBOX_BASE_URL, then this
  timeout: 30_000,                           # receive timeout in milliseconds
  max_retries: 2,                            # 0 disables retries
  req_options: []                            # merged into every Req request
)
```

The client sends `Authorization: Bearer <key>`, `User-Agent: ayinbox-elixir/0.1.0` and `Accept: application/json`. Inspecting the client struct never shows the key, and no error message contains it.

Per-call options on every function: `:idempotency_key`, `:timeout` (milliseconds) and `:headers` (extra request headers).

## Errors

Every call returns `{:ok, result}` or `{:error, %AyInbox.Error{}}`. The error carries `type`, `status`, `code` (the API's stable machine key), `message`, `reason`, `request_id`, `retry_after` (seconds, on a 429), the decoded `body` and the response `headers`. Branch on `type` and `code`, never on `message`.

| `type` | Status | Examples of `code` |
|---|---|---|
| `:bad_request` | 400 | `bad_request`, `invalid_cursor`, `duplicate_query_parameter` |
| `:authentication` | 401 | `unauthorized`, `api_key_holder_left` |
| `:payment_required` | 402 | `insufficient_credits` |
| `:permission_denied` | 403 | `forbidden`, `api_key_mailbox_limited` |
| `:not_found` | 404 | `not_found` |
| `:conflict` | 409 | `conflict`, `idempotency_outcome_unknown`, `contact_email_taken` |
| `:unprocessable` | 422 | `unprocessable`, `idempotency_key_required` |
| `:rate_limit` | 429 | `rate_limit_exceeded` |
| `:service_unavailable` | 503 | `service_unavailable` |
| `:internal_server` | 500, 501, 502, 504 | `internal_error` |
| `:connection`, `:timeout` | none | network failure or timeout |

Helpers: `AyInbox.Error.validation?/1` (400 or 422), `authentication?/1`, `permission_denied?/1`, `not_found?/1`, `conflict?/1`, `rate_limited?/1`, `server_error?/1`, `network?/1`. `AyInbox.Error` is an exception, so `raise error` works.

Some 429 answers carry no `code` and no `request_id`; the client fills `code` with `rate_limit_exceeded` and reads the wait from `Retry-After`, `retry_after` or `retry_after_ms`.

## Retries and timeouts

The client retries 429, 502, 503, 504, connection errors and timeouts, up to `max_retries` times (default 2, so 3 attempts). It waits for `Retry-After` when the server sends one (capped at 120 seconds), otherwise exponential backoff with full jitter (base 0.5 s, cap 8 s).

It never retries a 500, and it never retries a `POST` or `PATCH` that carries no idempotency key, except on 429, which the server refuses before running anything. `GET`, `PUT` and `DELETE` are retried. The client does not generate idempotency keys for you: pass one to make a write retryable.

The default receive timeout is 30 seconds; set `:timeout` on the client or on one call.

## Pagination

`list` functions return one page: `%{"data" => [...], "pagination" => %{"next_cursor" => ..., "has_more" => ...}}`. Pass `next_cursor` back as `cursor` for the next page and never parse it.

`stream` functions (and `AyInbox.paginate/3` for any paginated route) return a lazy `Stream` that walks every page, resending the same query and body:

```elixir
emails =
  client
  |> AyInbox.Contacts.stream(%{campaign_ids: [campaign_id], limit: 100})
  |> Stream.map(& &1["email"])
  |> Enum.to_list()

client
|> AyInbox.paginate("/suppressions", query: %{limit: 200})
|> Enum.take(10)
```

An error while walking raises `AyInbox.Error`. A 429 is waited out first, within `max_retries`. Recommended `limit` is 1 to 100.

## Idempotency

Every mutating call accepts `idempotency_key:`, sent as the `Idempotency-Key` header. The server keeps the completed response for 24 hours per workspace and key and replays it for the same request. The same key with a different request answers `409 conflict`. If the first attempt ended without a definite outcome, the key answers `409 idempotency_outcome_unknown` for 24 hours: find out whether the change happened before trying again with a new key.

## Webhooks

Verify each delivery against the raw request body, before any JSON parsing:

```elixir
signature = conn |> Plug.Conn.get_req_header("x-ayinbox-signature") |> List.first()

case AyInbox.Webhooks.construct_event(raw_body, signature, System.fetch_env!("AYINBOX_WEBHOOK_SECRET")) do
  {:ok, event} -> handle(event["event_type"], event["data"])
  {:error, _} -> Plug.Conn.send_resp(conn, 400, "bad signature")
end
```

The secret is the `whsec_...` string shown when the endpoint was created or its secret rotated; use it as is, prefix included. Signatures older than 300 seconds are refused (`tolerance:` changes that). The compare is constant time. Deduplicate on the `X-Ayinbox-Event-Id` header, which stays the same across retries.

## Calls that send email

These calls put real email on the wire:

- `campaigns.start` (`POST /campaigns/{id}/start`): needs `START_CAMPAIGNS` or `SEND_CAMPAIGNS`.
- `campaigns.update` with `status: "active"` (and `completed` or `paused_undeliverable`): needs `START_CAMPAIGNS` or `SEND_CAMPAIGNS` in addition to `WRITE_CAMPAIGNS`.
- `campaigns.leads.resume` on a finished campaign: needs `START_CAMPAIGNS` or `SEND_CAMPAIGNS`.
- `unibox.reply` and `unibox.approveAgentDraft`: need `WRITE_UNIBOX`. A key with `WRITE_UNIBOX` can send replies from any mailbox it can reach.
- Through `request`: `POST /unibox/compose`, `POST /emails/{id}/send`, `POST /campaigns/{id}/test-email`, the first-email review queue (`/campaigns/{id}/reviews/...`), placement tests: `SEND_CAMPAIGNS` (compose: `WRITE_UNIBOX`).

In this library all of those go through `AyInbox.request/4`; none of them has a named function.

Adding contacts can send mail without calling start: contacts added to an `active` campaign are queued; a `completed` campaign starts again on its own when leads are added; a contact that comes to match a segment linked to a sending campaign is enrolled. That includes `AyInbox.Contacts.create/3` and `AyInbox.Contacts.update/4` with `campaigns`.

`START_CAMPAIGNS` starts, resumes and pauses campaigns and nothing else. `SEND_CAMPAIGNS` covers everything `START_CAMPAIGNS` covers plus the other sending actions. `WRITE_CAMPAIGNS` alone edits drafts and pauses, and cannot start anything.

A key for a model that reads the inbox should use the "Agent: read and draft" preset (84574239): every read scope plus `AI_DRAFT`, with nothing that writes or sends.

Some calls spend workspace credits (AI drafts, research, enrichment, paid tools). They answer `402 insufficient_credits` when the balance is out.

Retrying a send without an idempotency key can send twice. Pass an idempotency key on every mutating call you might retry.

## Examples

- `examples/list_campaigns.exs`: list every campaign (`AYINBOX_API_KEY=aybox_... elixir examples/list_campaigns.exs`).
- `examples/verify_webhook.exs`: verify a signed delivery.

## Documentation

- API reference: https://docs.ayinbox.com/api/
- Product docs: https://docs.ayinbox.com/

## License

MIT. See `LICENSE`.
