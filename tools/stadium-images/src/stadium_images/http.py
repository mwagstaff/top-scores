from __future__ import annotations

import os
import random
import time
from pathlib import Path
from typing import Self
from urllib.parse import urlparse

import httpx


class HTTPError(RuntimeError):
    pass


class RateLimitError(HTTPError):
    def __init__(self, url: str, retry_after: float | None) -> None:
        self.url = url
        self.retry_after = retry_after
        detail = (
            f"; provider requested a retry after {retry_after:.0f} seconds"
            if retry_after is not None
            else ""
        )
        super().__init__(f"Rate limited by {url}{detail}")


class HTTPClient:
    def __init__(
        self,
        *,
        timeout: float = 30.0,
        minimum_interval: float = 0.15,
        max_attempts: int = 4,
        max_inline_retry_wait: float = 30.0,
    ) -> None:
        user_agent = os.getenv(
            "STADIUM_IMAGES_USER_AGENT",
            "TopScoresStadiumImageCollector/0.1 (personal, licence-aware image research)",
        )
        self.client = httpx.Client(
            timeout=httpx.Timeout(timeout),
            follow_redirects=True,
            headers={"User-Agent": user_agent},
        )
        self.minimum_interval = minimum_interval
        self.max_attempts = max_attempts
        self.max_inline_retry_wait = max_inline_retry_wait
        self.last_request_by_host: dict[str, float] = {}

    def close(self) -> None:
        self.client.close()

    def __enter__(self) -> Self:
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def get_json(
        self,
        url: str,
        *,
        params: dict[str, object] | None = None,
        headers: dict[str, str] | None = None,
    ) -> dict[str, object]:
        response = self._request("GET", url, params=params, headers=headers)
        try:
            value = response.json()
        except ValueError as error:
            raise HTTPError(f"Non-JSON response from {url}") from error
        if not isinstance(value, dict):
            raise HTTPError(f"Unexpected JSON response from {url}")
        return value

    def notify_download(
        self, url: str, *, headers: dict[str, str] | None = None
    ) -> None:
        self._request("GET", url, headers=headers)

    def download(self, url: str, destination: Path) -> None:
        destination.parent.mkdir(parents=True, exist_ok=True)
        response = self._request("GET", url)
        temporary = destination.with_suffix(destination.suffix + ".part")
        try:
            with temporary.open("wb") as output:
                for chunk in response.iter_bytes(chunk_size=1024 * 128):
                    output.write(chunk)
            temporary.replace(destination)
        finally:
            temporary.unlink(missing_ok=True)

    def _request(self, method: str, url: str, **kwargs: object) -> httpx.Response:
        last_error: Exception | None = None
        for attempt in range(self.max_attempts):
            self._respect_rate_limit(url)
            try:
                response = self.client.request(method, url, **kwargs)
            except (
                httpx.TimeoutException,
                httpx.NetworkError,
            ) as error:
                last_error = error
                if attempt + 1 == self.max_attempts:
                    break
                time.sleep(min(30.0, 2**attempt + random.random()))
                continue

            if response.status_code == 429:
                retry_after = self._retry_after(response)
                if retry_after is not None and retry_after > self.max_inline_retry_wait:
                    raise RateLimitError(url, retry_after)
                last_error = RateLimitError(url, retry_after)
                if attempt + 1 == self.max_attempts:
                    raise last_error
                time.sleep(
                    retry_after
                    if retry_after is not None
                    else self._exponential_delay(attempt)
                )
                continue

            if response.status_code >= 500:
                last_error = httpx.HTTPStatusError(
                    f"Retryable HTTP {response.status_code}",
                    request=response.request,
                    response=response,
                )
                if attempt + 1 == self.max_attempts:
                    break
                time.sleep(self._exponential_delay(attempt))
                continue

            try:
                response.raise_for_status()
            except httpx.HTTPStatusError as error:
                raise HTTPError(f"HTTP {response.status_code} from {url}") from error
            return response
        raise HTTPError(
            f"Request failed after {self.max_attempts} attempts: {url}"
        ) from last_error

    def _respect_rate_limit(self, url: str) -> None:
        host = urlparse(url).netloc
        now = time.monotonic()
        elapsed = now - self.last_request_by_host.get(host, 0.0)
        if elapsed < self.minimum_interval:
            time.sleep(self.minimum_interval - elapsed)
        self.last_request_by_host[host] = time.monotonic()

    @staticmethod
    def _retry_after(response: httpx.Response) -> float | None:
        retry_after = response.headers.get("Retry-After")
        if retry_after:
            try:
                return max(0.0, float(retry_after))
            except ValueError:
                pass
        return None

    @staticmethod
    def _exponential_delay(attempt: int) -> float:
        return min(30.0, 2**attempt + random.random())
