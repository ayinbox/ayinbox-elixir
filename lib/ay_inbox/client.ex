defmodule AyInbox.Client do
  @moduledoc """
  The client struct and the HTTP core: auth, retries, error mapping and pagination.

  Build one with `AyInbox.new/1`. The struct never shows the API key when inspected.
  """

  alias AyInbox.Error

  @version "0.1.0"
  @default_base_url "https://api.ayinbox.com/v1"
  @retry_statuses [429, 502, 503, 504]
  @max_retry_after_ms 120_000
  @backoff_base_ms 500
  @backoff_cap_ms 8_000

  @derive {Inspect, except: [:api_key]}
  defstruct api_key: nil,
            base_url: @default_base_url,
            timeout: 30_000,
            max_retries: 2,
            req_options: [],
            sleep: nil

  @type t :: %__MODULE__{
          api_key: String.t(),
          base_url: String.t(),
          timeout: non_neg_integer(),
          max_retries: non_neg_integer(),
          req_options: keyword(),
          sleep: (non_neg_integer() -> any()) | nil
        }

  @type result :: {:ok, term()} | {:error, Error.t()}

  @doc "The SDK version sent in the `User-Agent` header."
  def version, do: @version

  @doc false
  def new(opts) do
    api_key = present(opts[:api_key]) || present(System.get_env("AYINBOX_API_KEY"))

    if is_nil(api_key) do
      raise ArgumentError, "an API key is required: pass :api_key or set AYINBOX_API_KEY"
    end

    base_url =
      (present(opts[:base_url]) || present(System.get_env("AYINBOX_BASE_URL")) ||
         @default_base_url)
      |> String.trim_trailing("/")

    %__MODULE__{
      api_key: api_key,
      base_url: base_url,
      timeout: Keyword.get(opts, :timeout, 30_000),
      max_retries: Keyword.get(opts, :max_retries, 2),
      req_options: Keyword.get(opts, :req_options, []),
      sleep: Keyword.get(opts, :sleep)
    }
  end

  @doc false
  def request(%__MODULE__{} = client, method, path, opts) do
    method = normalize_method(method)
    idempotency_key = opts[:idempotency_key]
    req_opts = build(client, method, path, opts)
    attempt(client, method, idempotency_key, req_opts, 0)
  end

  @doc false
  def paginate(%__MODULE__{} = client, path, opts) do
    method = Keyword.get(opts, :method, :get)
    query = opts |> Keyword.get(:query, []) |> Map.new() |> Map.drop([:cursor, "cursor"])

    Stream.resource(
      fn -> :first end,
      fn
        :done ->
          {:halt, :done}

        cursor ->
          page_query = if cursor == :first, do: query, else: Map.put(query, "cursor", cursor)
          page_opts = Keyword.put(opts, :query, page_query)

          case request(client, method, path, page_opts) do
            {:ok, %{"data" => data} = page} when is_list(data) -> {data, next_cursor(page)}
            {:ok, other} -> raise unexpected(other)
            {:error, error} -> raise error
          end
      end,
      fn _ -> :ok end
    )
  end

  @doc false
  def segment(value), do: value |> to_string() |> URI.encode(&URI.char_unreserved?/1)

  @doc false
  def split_params(params, query_keys) do
    params
    |> Map.new()
    |> Enum.split_with(fn {key, _} -> to_string(key) in query_keys end)
    |> then(fn {query, body} -> {Map.new(query), Map.new(body)} end)
  end

  defp next_cursor(%{"pagination" => %{"has_more" => true, "next_cursor" => cursor}})
       when is_binary(cursor) and cursor != "",
       do: cursor

  defp next_cursor(_page), do: :done

  defp unexpected(body) do
    %Error{
      type: :unexpected_response,
      message: "expected a data and pagination envelope",
      body: body
    }
  end

  defp attempt(client, method, idempotency_key, req_opts, n) do
    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status} = resp} when status in 200..299 ->
        {:ok, decode_body(resp.body)}

      {:ok, %Req.Response{} = resp} ->
        error = Error.from_response(resp)

        if n < client.max_retries and retry_status?(resp.status, method, idempotency_key) do
          pause(client, error.retry_after, n)
          attempt(client, method, idempotency_key, req_opts, n + 1)
        else
          {:error, error}
        end

      {:error, exception} ->
        error = Error.from_exception(exception)

        if n < client.max_retries and replay_safe?(method, idempotency_key) do
          pause(client, nil, n)
          attempt(client, method, idempotency_key, req_opts, n + 1)
        else
          {:error, error}
        end
    end
  end

  # A 429 never ran the request, so it is safe to retry whatever the method.
  defp retry_status?(429, _method, _key), do: true

  defp retry_status?(status, method, key) when status in @retry_statuses,
    do: replay_safe?(method, key)

  defp retry_status?(_status, _method, _key), do: false

  defp replay_safe?(method, key) when method in [:post, :patch], do: present(key) != nil
  defp replay_safe?(_method, _key), do: true

  defp pause(client, retry_after, n) do
    ms =
      if is_integer(retry_after) do
        min(retry_after * 1000, @max_retry_after_ms)
      else
        :rand.uniform(min(@backoff_cap_ms, @backoff_base_ms * Integer.pow(2, n)) + 1) - 1
      end

    sleep = client.sleep || (&Process.sleep/1)
    sleep.(ms)
  end

  defp build(client, method, path, opts) do
    headers =
      [
        {"authorization", "Bearer " <> client.api_key},
        {"user-agent", "ayinbox-elixir/" <> @version},
        {"accept", "application/json"}
      ] ++ idempotency_header(opts[:idempotency_key]) ++ extra_headers(opts[:headers])

    base = [
      method: method,
      url: client.base_url <> ensure_leading_slash(path),
      headers: headers,
      params: clean_query(opts[:query]),
      receive_timeout: opts[:timeout] || client.timeout,
      retry: false,
      decode_body: false,
      redirect: false
    ]

    base =
      case Keyword.fetch(opts, :body) do
        {:ok, nil} -> base
        {:ok, body} -> Keyword.put(base, :json, body)
        :error -> base
      end

    Keyword.merge(client.req_options, base)
  end

  defp idempotency_header(key) do
    case present(key) do
      nil -> []
      key -> [{"idempotency-key", key}]
    end
  end

  defp extra_headers(nil), do: []

  defp extra_headers(headers) do
    Enum.map(headers, fn {name, value} -> {String.downcase(to_string(name)), to_string(value)} end)
  end

  defp clean_query(nil), do: []

  defp clean_query(query) do
    query
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.map(fn {key, value} -> {to_string(key), query_value(value)} end)
  end

  defp query_value(values) when is_list(values), do: Enum.map_join(values, ",", &to_string/1)
  defp query_value(value), do: to_string(value)

  defp ensure_leading_slash("/" <> _ = path), do: path
  defp ensure_leading_slash(path), do: "/" <> path

  defp decode_body(body) when body in [nil, ""], do: nil

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> body
    end
  end

  defp decode_body(body), do: body

  defp normalize_method(method) when is_atom(method), do: method

  defp normalize_method(method) when is_binary(method),
    do: method |> String.downcase() |> String.to_existing_atom()

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil
end
