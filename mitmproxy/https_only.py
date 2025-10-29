from mitmproxy import ctx, http


def request(flow: http.HTTPFlow) -> None:
    ctx.log.info(
        f"Proxy handling request: {flow.request.method} {flow.request.pretty_url} headers={dict(flow.request.headers)}"
    )
    scheme = flow.request.scheme
    if scheme != "https":
        flow.response = http.Response.make(
            403,
            b"Only HTTPS requests are permitted through the Codex workspace proxy.",
            {"Content-Type": "text/plain"},
        )
        return

    upgrade_header = flow.request.headers.get("upgrade", "").lower()
    connection_header = flow.request.headers.get("connection", "").lower()
    if "websocket" in upgrade_header or "upgrade" in connection_header:
        ctx.log.info("Blocking websocket upgrade attempt")
        flow.response = http.Response.make(
            403,
            b"WebSocket (wss) traffic is blocked in the Codex workspace proxy.",
            {"Content-Type": "text/plain"},
        )


def websocket_start(flow) -> None:
    ctx.log.info("Killing websocket connection")
    flow.kill()
