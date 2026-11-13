# Run with: elixir examples/verify_webhook.exs
Mix.install([{:ayinbox, github: "ayinbox/ayinbox-elixir"}])

secret = "whsec_test_secret"
timestamp = 1_700_000_000

body =
  ~s({"id":"00000000-0000-4000-8000-000000000001",) <>
    ~s("event_type":"campaign.reply_received",) <>
    ~s("organization_id":"00000000-0000-4000-8000-0000000000aa",) <>
    ~s("created_at":"2023-11-14T22:13:20Z","data":{}})

header = "t=1700000000,v1=d1efe3010ae2523566985158ab4852f8f3569365a06941ef87e3a641e3171342"

case AyInbox.Webhooks.construct_event(body, header, secret, now: timestamp) do
  {:ok, event} -> IO.puts("verified #{event["event_type"]} #{event["id"]}")
  {:error, error} -> IO.puts("rejected: #{Exception.message(error)}")
end
