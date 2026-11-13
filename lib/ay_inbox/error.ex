defmodule AyInbox.Error do
  @moduledoc """
  The one error every AY Inbox call returns.

  Branch on `type` (the category) and `code` (the API's stable machine key).
  `message` is human text and should not be matched on.

  | `type` | Status |
  |---|---|
  | `:bad_request` | 400 |
  | `:authentication` | 401 |
  | `:payment_required` | 402 |
  | `:permission_denied` | 403 |
  | `:not_found` | 404 |
  | `:conflict` | 409 |
  | `:unprocessable` | 422 |
  | `:rate_limit` | 429 (`retry_after` holds seconds when known) |
  | `:service_unavailable` | 503 |
  | `:internal_server` | 500, 501, 502, 504 and any other 5xx |
  | `:api_error` | any other non-2xx status |
  | `:connection` | network failure, DNS, TLS |
  | `:timeout` | the request timed out |
  | `:signature_verification` | a webhook signature did not verify |
  | `:unexpected_response` | a paginated path did not answer with `data` and `pagination` |
  """

  @type error_type ::
          :bad_request
          | :authentication
          | :payment_required
          | :permission_denied
          | :not_found
          | :conflict
          | :unprocessable
          | :rate_limit
          | :service_unavailable
          | :internal_server
          | :api_error
          | :connection
          | :timeout
          | :signature_verification
          | :unexpected_response

  @type t :: %__MODULE__{
          type: error_type(),
          status: non_neg_integer() | nil,
          code: String.t() | nil,
          message: String.t(),
          reason: String.t() | nil,
          request_id: String.t() | nil,
          retry_after: non_neg_integer() | nil,
          body: term(),
          headers: map()
        }

  defexception type: :api_error,
               status: nil,
               code: nil,
               message: "",
               reason: nil,
               request_id: nil,
               retry_after: nil,
               body: nil,
               headers: %{}

  @default_codes %{
    400 => "bad_request",
    401 => "unauthorized",
    402 => "insufficient_credits",
    403 => "forbidden",
    404 => "not_found",
    409 => "conflict",
    422 => "unprocessable",
    429 => "rate_limit_exceeded",
    500 => "internal_error",
    501 => "not_implemented",
    503 => "service_unavailable"
  }

  @impl true
  def message(%__MODULE__{status: nil, type: type, message: msg}), do: "#{type}: #{msg}"

  def message(%__MODULE__{} = e) do
    base = "#{e.status} #{e.code}: #{e.message}"
    if e.request_id, do: base <> " (request_id #{e.request_id})", else: base
  end

  @doc "True for a 400 or 422 answer."
  def validation?(%__MODULE__{type: type}), do: type in [:bad_request, :unprocessable]

  @doc "True for a 401 answer."
  def authentication?(%__MODULE__{type: type}), do: type == :authentication

  @doc "True for a 403 answer."
  def permission_denied?(%__MODULE__{type: type}), do: type == :permission_denied

  @doc "True for a 404 answer."
  def not_found?(%__MODULE__{type: type}), do: type == :not_found

  @doc "True for a 409 answer."
  def conflict?(%__MODULE__{type: type}), do: type == :conflict

  @doc "True for a 429 answer."
  def rate_limited?(%__MODULE__{type: type}), do: type == :rate_limit

  @doc "True for any 5xx answer."
  def server_error?(%__MODULE__{type: type}), do: type in [:internal_server, :service_unavailable]

  @doc "True for a network failure or a timeout."
  def network?(%__MODULE__{type: type}), do: type in [:connection, :timeout]

  @doc false
  def from_response(%Req.Response{status: status, body: raw} = resp) do
    raw = if is_binary(raw), do: raw, else: ""
    decoded = decode(raw)
    headers = resp.headers

    %__MODULE__{
      type: type_for(status),
      status: status,
      code: code(decoded, status),
      message: message_text(decoded, raw, status),
      reason: field(decoded, "reason"),
      request_id: field(decoded, "request_id") || header(headers, "x-request-id"),
      retry_after: retry_after(headers, decoded),
      body: decoded || raw,
      headers: headers
    }
  end

  @doc false
  def from_exception(%Req.TransportError{reason: :timeout} = e) do
    %__MODULE__{type: :timeout, message: Exception.message(e)}
  end

  def from_exception(e) when is_exception(e) do
    %__MODULE__{type: :connection, message: Exception.message(e)}
  end

  def from_exception(other) do
    %__MODULE__{type: :connection, message: inspect(other)}
  end

  defp decode(""), do: nil

  defp decode(raw) do
    case Jason.decode(raw) do
      {:ok, map} when is_map(map) -> map
      _ -> nil
    end
  end

  defp type_for(400), do: :bad_request
  defp type_for(401), do: :authentication
  defp type_for(402), do: :payment_required
  defp type_for(403), do: :permission_denied
  defp type_for(404), do: :not_found
  defp type_for(409), do: :conflict
  defp type_for(422), do: :unprocessable
  defp type_for(429), do: :rate_limit
  defp type_for(503), do: :service_unavailable
  defp type_for(status) when status >= 500, do: :internal_server
  defp type_for(_), do: :api_error

  defp code(decoded, status) do
    case {field(decoded, "code"), field(decoded, "error")} do
      {code, _} when is_binary(code) and code != "" ->
        code

      {_, error} when is_binary(error) ->
        if Regex.match?(~r/^[a-z0-9_]+$/, error), do: error, else: default_code(status)

      _ ->
        default_code(status)
    end
  end

  defp default_code(status), do: Map.get(@default_codes, status, "http_#{status}")

  defp message_text(decoded, raw, status) do
    case field(decoded, "message") do
      msg when is_binary(msg) and msg != "" -> msg
      _ when raw != "" -> raw
      _ -> "HTTP #{status}"
    end
  end

  defp retry_after(headers, decoded) do
    from_header = headers |> header("retry-after") |> parse_int()
    seconds = field(decoded, "retry_after")
    millis = field(decoded, "retry_after_ms")

    cond do
      is_integer(from_header) -> from_header
      is_integer(seconds) -> seconds
      is_number(millis) -> ceil(millis / 1000)
      true -> nil
    end
  end

  defp parse_int(nil), do: nil

  defp parse_int(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} when n >= 0 -> n
      _ -> nil
    end
  end

  defp field(nil, _key), do: nil
  defp field(map, key), do: Map.get(map, key)

  defp header(headers, name) do
    case Map.get(headers, name) do
      [value | _] -> value
      value when is_binary(value) -> value
      _ -> nil
    end
  end
end
