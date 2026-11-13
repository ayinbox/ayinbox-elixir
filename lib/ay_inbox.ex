defmodule AyInbox do
  @moduledoc """
  Elixir client for the AY Inbox REST API (`https://api.ayinbox.com/v1`).

      client = AyInbox.new()
      {:ok, me} = AyInbox.Me.get(client)

  Every call returns `{:ok, result}` or `{:error, %AyInbox.Error{}}`. Results are the
  decoded JSON with string keys, so fields the API adds later are kept, never an error.

  Resources: `AyInbox.Me`, `AyInbox.Campaigns`, `AyInbox.Contacts`, `AyInbox.Mailboxes`,
  `AyInbox.Unibox` and `AyInbox.Webhooks`. Every other route is reachable through
  `request/4`, and any paginated route through `paginate/3`.

  ## Per-call options

  Every function that calls the API takes a final `opts` keyword list:

    * `:idempotency_key` - sent as `Idempotency-Key` (mutating calls)
    * `:timeout` - receive timeout in milliseconds for this call
    * `:headers` - extra request headers, as a map or a list of pairs
  """

  alias AyInbox.Client

  @doc """
  Builds a client.

  ## Options

    * `:api_key` - an `aybox_` API key or an `ayat_` OAuth token. Falls back to
      `AYINBOX_API_KEY`; raises `ArgumentError` when neither is set
    * `:base_url` - defaults to `AYINBOX_BASE_URL`, then `https://api.ayinbox.com/v1`
    * `:timeout` - receive timeout in milliseconds, default `30_000`
    * `:max_retries` - automatic retries, default `2`; `0` disables them
    * `:req_options` - extra options merged into every `Req` request, for example
      `[plug: {Req.Test, MyStub}]` in tests or `[connect_options: [...]]`
    * `:sleep` - a one-argument function called with the wait in milliseconds
      between retries (defaults to `Process.sleep/1`; useful in tests)
  """
  @spec new(keyword()) :: Client.t()
  def new(opts \\ []), do: Client.new(opts)

  @doc """
  Calls any route with the client's auth, retries and error mapping.

  `path` is relative to the base URL, for example `"/campaigns-overview"`.

  ## Options

    * `:query` - query parameters (map or keyword; `nil` values are dropped,
      lists are joined with commas)
    * `:body` - a term encoded as the JSON body
    * `:idempotency_key`, `:timeout`, `:headers` - see the module docs

  The result is the decoded JSON, `nil` for an empty body, or the raw binary when
  the body is not JSON.
  """
  @spec request(Client.t(), atom() | String.t(), String.t(), keyword()) :: Client.result()
  def request(client, method, path, opts \\ []), do: Client.request(client, method, path, opts)

  @doc """
  Returns a lazy `Stream` over every item of a paginated route.

  It requests the first page without a cursor, then follows `next_cursor` while
  `has_more` is true, resending the same query and body. An error while walking
  raises `AyInbox.Error`.

  ## Options

    * `:method` - default `:get`; `POST /contacts/search` uses `:post`
    * `:query`, `:body`, `:timeout`, `:headers` - as in `request/4`

  ## Example

      client
      |> AyInbox.paginate("/campaigns", query: %{status: "active"})
      |> Enum.map(& &1["name"])
  """
  @spec paginate(Client.t(), String.t(), keyword()) :: Enumerable.t()
  def paginate(client, path, opts \\ []), do: Client.paginate(client, path, opts)
end
