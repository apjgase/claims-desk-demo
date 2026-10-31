"""Small client for an OpenAI-compatible endpoint (NAI, vLLM): chat completions, streaming,
tool calls, image parts, and the model list. httpx only, no SDK."""
import json
from typing import Any, AsyncIterator, Dict, List, Optional

import httpx


class LLMError(Exception):
    pass


def _detail(response: httpx.Response) -> str:
    text = response.text.strip()
    try:
        body = response.json()
        err = body.get("error") if isinstance(body, dict) else None
        if isinstance(err, dict):
            text = err.get("message") or text
        elif isinstance(body, dict) and body.get("detail"):
            text = str(body["detail"])
    except ValueError:
        pass
    return "LLM endpoint answered {}: {}".format(response.status_code, (text.splitlines() or ["no body"])[0][:200])


class Client:
    def __init__(self, base_url: str, api_key: str, verify: bool = True, timeout: float = 120,
                 transport: Optional[httpx.AsyncBaseTransport] = None):
        if not base_url:
            raise LLMError("llm_base_url is not set")
        self.base_url = base_url.rstrip("/")
        headers = {"Authorization": "Bearer " + api_key} if api_key else {}
        self._http = httpx.AsyncClient(base_url=self.base_url, headers=headers, verify=verify,
                                       timeout=httpx.Timeout(timeout, connect=10), transport=transport)

    async def aclose(self) -> None:
        await self._http.aclose()

    async def models(self) -> List[str]:
        try:
            response = await self._http.get("/models", timeout=8)
        except httpx.HTTPError as exc:
            raise LLMError("cannot reach {} ({})".format(self.base_url, type(exc).__name__)) from exc
        if response.status_code >= 400:
            raise LLMError(_detail(response))
        return [m.get("id") for m in response.json().get("data", []) if isinstance(m, dict)]

    async def complete(self, model: str, messages: List[Dict[str, Any]], max_tokens: int = 600,
                       temperature: float = 0.2, timeout: Optional[float] = None) -> str:
        """One non-streamed answer. Used for the photo description and the scope check."""
        body = {"model": model, "messages": messages, "max_tokens": max_tokens, "temperature": temperature}
        extra = {"timeout": httpx.Timeout(timeout, connect=10)} if timeout else {}
        try:
            response = await self._http.post("/chat/completions", json=body, **extra)
        except httpx.HTTPError as exc:
            raise LLMError("cannot reach {} ({})".format(self.base_url, type(exc).__name__)) from exc
        if response.status_code >= 400:
            raise LLMError(_detail(response))
        choice = (response.json().get("choices") or [{}])[0]
        return (choice.get("message") or {}).get("content") or ""

    async def stream(self, model: str, messages: List[Dict[str, Any]],
                     tools: Optional[List[Dict[str, Any]]] = None,
                     max_tokens: int = 1500) -> AsyncIterator[Dict[str, Any]]:
        """Yields {"type": "content", "text"} as tokens arrive, then one
        {"type": "end", "content", "tool_calls", "finish_reason"}. Reasoning tokens are dropped."""
        body: Dict[str, Any] = {"model": model, "messages": messages, "max_tokens": max_tokens,
                                "temperature": 0.2, "stream": True}
        if tools:
            body["tools"] = tools
            body["tool_choice"] = "auto"
        content: List[str] = []
        calls: Dict[int, Dict[str, Any]] = {}
        finish = None
        try:
            async with self._http.stream("POST", "/chat/completions", json=body) as response:
                if response.status_code >= 400:
                    await response.aread()
                    raise LLMError(_detail(response))
                async for line in response.aiter_lines():
                    if not line.startswith("data:"):
                        continue
                    data = line[5:].strip()
                    if data == "[DONE]":
                        break
                    try:
                        chunk = json.loads(data)
                    except ValueError:
                        continue
                    for choice in chunk.get("choices") or []:
                        delta = choice.get("delta") or {}
                        if delta.get("content"):
                            content.append(delta["content"])
                            yield {"type": "content", "text": delta["content"]}
                        for part in delta.get("tool_calls") or []:
                            slot = calls.setdefault(part.get("index", 0),
                                                    {"id": "", "type": "function",
                                                     "function": {"name": "", "arguments": ""}})
                            if part.get("id"):
                                slot["id"] = part["id"]
                            fn = part.get("function") or {}
                            slot["function"]["name"] += fn.get("name") or ""
                            slot["function"]["arguments"] += fn.get("arguments") or ""
                        finish = choice.get("finish_reason") or finish
        except httpx.HTTPError as exc:
            raise LLMError("lost the connection to {} ({})".format(self.base_url, type(exc).__name__)) from exc
        tool_calls = [calls[i] for i in sorted(calls)]
        for n, call in enumerate(tool_calls):
            call["id"] = call["id"] or "call_{}".format(n)
        yield {"type": "end", "content": "".join(content), "tool_calls": tool_calls, "finish_reason": finish}
