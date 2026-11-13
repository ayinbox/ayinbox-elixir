# Run with: AYINBOX_API_KEY=aybox_... elixir examples/list_campaigns.exs
Mix.install([{:ayinbox, github: "ayinbox/ayinbox-elixir"}])

client = AyInbox.new()

client
|> AyInbox.Campaigns.stream(%{limit: 100})
|> Enum.each(fn campaign ->
  IO.puts("#{campaign["id"]}  #{campaign["status"]}  #{campaign["name"]}")
end)
