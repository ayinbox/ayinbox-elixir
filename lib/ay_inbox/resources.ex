defmodule AyInbox.Me do
  @moduledoc "The identity behind the credential (`GET /me`)."

  alias AyInbox.Client

  @doc """
  Validates the credential and returns who it acts for: `user_id`, `email`,
  `organization_id`, `auth_type` and the lowercased `scopes`. Needs no scope.
  """
  @spec get(Client.t(), keyword()) :: Client.result()
  def get(client, opts \\ []), do: Client.request(client, :get, "/me", opts)
end

defmodule AyInbox.Campaigns do
  @moduledoc """
  Campaigns (`/campaigns`). Results are `Campaign` maps with string keys.

  Creating a campaign never sends mail. Starting one does: use
  `AyInbox.request(client, :post, "/campaigns/\#{id}/start", ...)` with a key that
  holds `START_CAMPAIGNS` or `SEND_CAMPAIGNS`.
  """

  alias AyInbox.Client

  @doc """
  Lists one page of campaigns. Needs `READ_CAMPAIGNS`.

  Params (sent as query): `q`, `status` (`draft`, `active`, `paused`, `completed`),
  `folder`, `cursor`, `limit` (1 to 100 recommended, default 50).
  """
  @spec list(Client.t(), map() | keyword(), keyword()) :: Client.result()
  def list(client, params \\ %{}, opts \\ []) do
    Client.request(client, :get, "/campaigns", Keyword.put(opts, :query, params))
  end

  @doc "Streams every campaign across pages. Takes the same params as `list/3`."
  @spec stream(Client.t(), map() | keyword(), keyword()) :: Enumerable.t()
  def stream(client, params \\ %{}, opts \\ []) do
    Client.paginate(client, "/campaigns", Keyword.put(opts, :query, params))
  end

  @doc "Gets one campaign. Needs `READ_CAMPAIGNS`."
  @spec get(Client.t(), String.t(), keyword()) :: Client.result()
  def get(client, id, opts \\ []) do
    Client.request(client, :get, "/campaigns/" <> Client.segment(id), opts)
  end

  @doc """
  Creates a draft campaign. Needs `WRITE_CAMPAIGNS`. Never sends mail.

  `params` needs `name`; see the API reference for the other fields (`steps`,
  `email_tag_ids`, `folder_ids`, `senders`, schedule fields and so on).
  """
  @spec create(Client.t(), map(), keyword()) :: Client.result()
  def create(client, params, opts \\ []) do
    Client.request(client, :post, "/campaigns", Keyword.put(opts, :body, params))
  end

  @doc """
  Pauses an active campaign (`POST /campaigns/{id}/stop`). Needs any of
  `WRITE_CAMPAIGNS`, `START_CAMPAIGNS` or `SEND_CAMPAIGNS`. Returns
  `%{"status" => "stopped"}`.
  """
  @spec pause(Client.t(), String.t(), keyword()) :: Client.result()
  def pause(client, id, opts \\ []) do
    Client.request(client, :post, "/campaigns/" <> Client.segment(id) <> "/stop", opts)
  end
end

defmodule AyInbox.Contacts do
  @moduledoc """
  Contacts (`/contacts`). Results are `Contact` maps with string keys.

  Adding a contact to an `active` campaign queues mail to it, and adding leads to a
  `completed` campaign starts it again on its own.
  """

  alias AyInbox.Client

  @query_keys ["cursor", "limit", "category"]

  @doc """
  Searches contacts (`POST /contacts/search`), one page. Needs `READ_CONTACTS`.

  `cursor`, `limit` and `category` go in the query; every other param is a search
  filter sent in the body (`query`, `campaign_ids`, `subscribed`, `sort_by`,
  `reverse` and so on). An empty map matches every contact. It only reads, so it
  is safe to retry and needs no idempotency key.
  """
  @spec list(Client.t(), map() | keyword(), keyword()) :: Client.result()
  def list(client, params \\ %{}, opts \\ []) do
    {query, body} = Client.split_params(params, @query_keys)
    opts = opts |> Keyword.put(:query, query) |> Keyword.put(:body, body)
    Client.request(client, :post, "/contacts/search", opts)
  end

  @doc "Streams every matching contact across pages. Takes the same params as `list/3`."
  @spec stream(Client.t(), map() | keyword(), keyword()) :: Enumerable.t()
  def stream(client, params \\ %{}, opts \\ []) do
    {query, body} = Client.split_params(params, @query_keys)
    opts = opts |> Keyword.merge(method: :post, query: query, body: body)
    Client.paginate(client, "/contacts/search", opts)
  end

  @doc "Gets one contact with its detail fields. Needs `READ_CONTACTS`."
  @spec get(Client.t(), String.t(), keyword()) :: Client.result()
  def get(client, id, opts \\ []) do
    Client.request(client, :get, "/contacts/" <> Client.segment(id), opts)
  end

  @doc """
  Creates or updates contacts by address (`POST /contacts`). Needs `WRITE_CONTACTS`.

  Pass one contact map (needs `email`) or a list of up to 10,240. The result is
  always a list of contacts. Can send mail: see the module docs.
  """
  @spec create(Client.t(), map() | [map()], keyword()) :: Client.result()
  def create(client, contacts, opts \\ []) do
    Client.request(client, :post, "/contacts", Keyword.put(opts, :body, contacts))
  end

  @doc """
  Updates one contact (`PATCH /contacts/{id}`). Needs `WRITE_CONTACTS`.

  `custom_fields`, `campaigns` and `categories` replace the stored values when sent.
  Changing `email` to an address another contact holds answers `409 contact_email_taken`.
  """
  @spec update(Client.t(), String.t(), map(), keyword()) :: Client.result()
  def update(client, id, params, opts \\ []) do
    path = "/contacts/" <> Client.segment(id)
    Client.request(client, :patch, path, Keyword.put(opts, :body, params))
  end

  @doc "Deletes one contact. Needs `WRITE_CONTACTS`. Returns `{:ok, nil}`."
  @spec delete(Client.t(), String.t(), keyword()) :: Client.result()
  def delete(client, id, opts \\ []) do
    Client.request(client, :delete, "/contacts/" <> Client.segment(id), opts)
  end
end

defmodule AyInbox.Mailboxes do
  @moduledoc "Connected mailboxes (`/emails`). Results are `Mailbox` maps with string keys."

  alias AyInbox.Client

  @doc """
  Lists one page of mailboxes. Needs `READ_EMAILS`.

  Params (query): `q`, `tag`, `cursor`, `limit` (1 to 100 recommended, default 50).
  """
  @spec list(Client.t(), map() | keyword(), keyword()) :: Client.result()
  def list(client, params \\ %{}, opts \\ []) do
    Client.request(client, :get, "/emails", Keyword.put(opts, :query, params))
  end

  @doc "Streams every mailbox across pages. Takes the same params as `list/3`."
  @spec stream(Client.t(), map() | keyword(), keyword()) :: Enumerable.t()
  def stream(client, params \\ %{}, opts \\ []) do
    Client.paginate(client, "/emails", Keyword.put(opts, :query, params))
  end
end

defmodule AyInbox.Unibox do
  @moduledoc """
  The Unibox: every reply across every connected mailbox. Needs `READ_UNIBOX` and an
  active trial or paid plan. Rows are `MessagePreview` maps with string keys.
  """

  alias AyInbox.Client

  @doc """
  Lists one page of conversations, one row per thread (`GET /unibox`).

  Params (query) include `cursor`, `limit` (1 to 100), `folder`, `direction`,
  `unseen`, `campaign_id`, `contact_id`, `email_id` and the others in the API
  reference. Spam, trash and archive are left out by default.
  """
  @spec list_threads(Client.t(), map() | keyword(), keyword()) :: Client.result()
  def list_threads(client, params \\ %{}, opts \\ []) do
    Client.request(client, :get, "/unibox", Keyword.put(opts, :query, params))
  end

  @doc "Streams every conversation across pages. Takes the same params as `list_threads/3`."
  @spec stream_threads(Client.t(), map() | keyword(), keyword()) :: Enumerable.t()
  def stream_threads(client, params \\ %{}, opts \\ []) do
    Client.paginate(client, "/unibox", Keyword.put(opts, :query, params))
  end

  @doc """
  Reads one page of a thread's messages (`GET /unibox/thread`).

  `thread_id` is the provider thread string. Optional params: `email_id` (one
  mailbox), `limit` (1 to 500, default 500), `cursor`. Rows are previews; read a
  body with `AyInbox.request(client, :get, "/unibox/\#{id}")`.
  """
  @spec get_thread(Client.t(), String.t(), map() | keyword(), keyword()) :: Client.result()
  def get_thread(client, thread_id, params \\ %{}, opts \\ []) do
    query = params |> Map.new() |> Map.put("thread_id", thread_id)
    Client.request(client, :get, "/unibox/thread", Keyword.put(opts, :query, query))
  end
end
