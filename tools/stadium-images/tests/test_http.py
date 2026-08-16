import httpx
import pytest

from stadium_images.http import HTTPClient, HTTPError, RateLimitError


def test_long_retry_after_fails_fast_without_repeated_requests() -> None:
    requests = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal requests
        requests += 1
        return httpx.Response(
            429,
            headers={"Retry-After": "600"},
            request=request,
        )

    client = HTTPClient(minimum_interval=0, max_inline_retry_wait=30)
    client.client.close()
    client.client = httpx.Client(transport=httpx.MockTransport(handler))
    try:
        with pytest.raises(RateLimitError) as error:
            client.get_json("https://upload.wikimedia.org/example.jpg")
    finally:
        client.close()

    assert requests == 1
    assert error.value.retry_after == 600


def test_non_retryable_http_error_is_not_retried() -> None:
    requests = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal requests
        requests += 1
        return httpx.Response(404, request=request)

    client = HTTPClient(minimum_interval=0)
    client.client.close()
    client.client = httpx.Client(transport=httpx.MockTransport(handler))
    try:
        with pytest.raises(HTTPError, match="HTTP 404"):
            client.get_json("https://example.com/missing")
    finally:
        client.close()

    assert requests == 1
