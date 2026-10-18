#!/usr/bin/env python3
"""Single-upstream L4 forwarder for airgapped ProgramBench inference.

ProgramBench's inference contract bans agent internet access (the agent
must rebuild each program from the compiled binary + bundled docs — any
source fetch is a disqualification). fa's LLM calls, however, come from
INSIDE the task container (the harbor-proven pattern, bench/harbor_fa/
fa_agent.py), so the container needs exactly one egress route: the
selected provider's API endpoint. The bench-programbench.yml run job puts
each task container on a docker `--internal` network (no external route)
and runs this forwarder on the HOST, bound to that network's gateway IP;
the container resolves the provider hostname to the gateway via /etc/hosts.
TLS stays end-to-end (this is a TCP pipe, not a proxy): the container's
ClientHello carries the real SNI and validates the provider's real
certificate — fa's baseUrl is byte-identical to a direct run.

Usage: llm_forwarder.py --listen <ip>:<port> --upstream <host>:<port>
Prints `forwarder ready on <listen> -> <upstream>` on stdout once the
listener is up (the workflow's readiness check), then serves until
terminated. One upstream only — a container that could reach this
forwarder can reach the provider API and NOTHING else.
"""

from __future__ import annotations

import argparse
import asyncio


async def _pipe(src: asyncio.StreamReader, dst: asyncio.StreamWriter) -> None:
    try:
        while chunk := await src.read(65536):
            dst.write(chunk)
            await dst.drain()
    except (ConnectionError, TimeoutError):
        pass
    finally:
        try:
            dst.close()
        except Exception:
            pass


async def _handle(
    client_reader: asyncio.StreamReader,
    client_writer: asyncio.StreamWriter,
    upstream: tuple[str, int],
) -> None:
    try:
        up_reader, up_writer = await asyncio.open_connection(*upstream)
    except OSError:
        client_writer.close()
        return
    await asyncio.gather(
        _pipe(client_reader, up_writer),
        _pipe(up_reader, client_writer),
    )


async def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen", required=True, help="ip:port to bind (the internal network's gateway IP)")
    parser.add_argument("--upstream", required=True, help="host:port forwarded to (the provider API endpoint)")
    args = parser.parse_args()
    listen_ip, listen_port = args.listen.rsplit(":", 1)
    up_host, up_port = args.upstream.rsplit(":", 1)
    server = await asyncio.start_server(
        lambda r, w: _handle(r, w, (up_host, int(up_port))),
        listen_ip,
        int(listen_port),
    )
    print(f"forwarder ready on {args.listen} -> {args.upstream}", flush=True)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
