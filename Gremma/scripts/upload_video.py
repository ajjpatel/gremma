#!/usr/bin/env python3
"""Stream an Arduino VENTUNO Q activity clip to Gremma over private Wi-Fi.

Enable Gremma's receiver and copy its address/token. Supply the token through the
GREMMA_UPLOAD_TOKEN environment variable, never through a command-line argument.
This API uses HTTP: use only a trusted private Wi-Fi network, without port forwarding.

Example:
    python3 Gremma/scripts/upload_video.py clip.mp4 \
      --url http://192.168.1.20:54321 \
      --recorded-at 2026-10-24T09:00:00-07:00 --room Kitchen

Use the actual recording start time, not the time the upload started. HTTP 202 means
the clip is saved and queued; E4B indexing continues in the iPhone app.
"""
from __future__ import annotations

import argparse
from datetime import datetime
import http.client
import ipaddress
import json
import os
from pathlib import Path
import socket
import sys
from urllib.parse import urlsplit

MAX_BYTES = 100 * 1024 * 1024
PRIVATE_NETWORKS = tuple(ipaddress.ip_network(value) for value in (
    "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16",
    "127.0.0.0/8", "::1/128", "fc00::/7", "fe80::/10",
))


def is_private_address(value: str) -> bool:
    try:
        address = ipaddress.ip_address(value.split("%", 1)[0])
    except ValueError:
        return False
    if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped:
        address = address.ipv4_mapped
    return any(address.version == network.version and address in network for network in PRIVATE_NETWORKS)


def destination(url: str) -> tuple[str, int, str]:
    parts = urlsplit(url)
    if (parts.scheme != "http" or not parts.hostname or parts.username is not None
            or parts.password is not None or parts.path not in ("", "/")
            or parts.query or parts.fragment):
        raise ValueError("Use the receiver's base HTTP address, without credentials or a path.")
    port = parts.port or 80
    candidates = socket.getaddrinfo(parts.hostname, port, type=socket.SOCK_STREAM)
    # Resolve once, then connect to the validated numeric address. A later DNS
    # change cannot redirect the token or video to a public address.
    candidates.sort(key=lambda entry: entry[0] != socket.AF_INET)
    for _, _, _, _, endpoint in candidates:
        if is_private_address(endpoint[0]):
            host = parts.hostname
            host_header = f"[{host}]:{port}" if ":" in host else f"{host}:{port}"
            return endpoint[0], port, host_header
    raise ValueError("The receiver must resolve to a private local address.")


def recording_timestamp(value: str) -> str:
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise ValueError("--recorded-at must be an ISO recording timestamp with a timezone.") from error
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise ValueError("--recorded-at requires a timezone, such as -07:00 or Z.")
    return parsed.isoformat(timespec="seconds")


def upload(path: Path, url: str, recorded_at: str, room: str, token: str, timeout: float = 180) -> dict:
    if not token or len(token) > 256 or any(ord(character) < 33 or ord(character) > 126 for character in token):
        raise ValueError("Set GREMMA_UPLOAD_TOKEN to the token shown in Gremma's receiver settings.")
    if not path.is_file():
        raise ValueError("The video file does not exist.")
    size = path.stat().st_size
    if not 0 < size <= MAX_BYTES:
        raise ValueError("Choose a nonempty video no larger than 100 MiB.")
    extension = path.suffix.lower()
    if extension not in (".mp4", ".m4v", ".mov"):
        raise ValueError("Choose an MP4 or MOV video.")
    if not 1 <= len(room) <= 100 or any(ord(character) < 32 or ord(character) > 126 for character in room):
        raise ValueError("Use a room name of 1 to 100 printable ASCII characters.")
    if not 0 < timeout <= 300:
        raise ValueError("Timeout must be between 0 and 300 seconds.")
    recorded_at = recording_timestamp(recorded_at)
    address, port, host_header = destination(url)
    connection = http.client.HTTPConnection(address, port, timeout=timeout)
    try:
        connection.putrequest("POST", "/v1/videos", skip_host=True, skip_accept_encoding=True)
        connection.putheader("Host", host_header)
        connection.putheader("Authorization", "Bearer " + token)
        connection.putheader("Content-Type", "video/quicktime" if extension == ".mov" else "video/mp4")
        connection.putheader("Content-Length", str(size))
        connection.putheader("X-Recorded-At", recorded_at)
        connection.putheader("X-Room", room)
        connection.putheader("Connection", "close")
        connection.endheaders()
        sent = 0
        with path.open("rb") as video:
            while sent < size:
                chunk = video.read(min(65_536, size - sent))
                if not chunk:
                    raise ValueError("The video changed during upload. Save the recording completely before uploading.")
                connection.send(chunk)
                sent += len(chunk)
            if video.read(1):
                raise ValueError("The video changed during upload. Save the recording completely before uploading.")
        response = connection.getresponse()
        raw = response.read(65_537)
        if len(raw) > 65_536:
            raise ValueError("The receiver returned an unexpected oversized response.")
        try:
            payload = json.loads(raw)
        except (ValueError, UnicodeError) as error:
            raise ValueError(f"The receiver returned an invalid response (HTTP {response.status}).") from error
        if response.status != 202 or not isinstance(payload, dict) or not isinstance(payload.get("video_id"), str):
            # Do not echo arbitrary response bodies: they could contain a token or
            # private details from an incorrectly configured endpoint.
            raise ValueError(f"Upload was not acknowledged (HTTP {response.status}). Check the receiver and video, then retry.")
        return {"status": "queued", "video_id": payload["video_id"]}
    finally:
        connection.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("file", type=Path)
    parser.add_argument("--url", required=True, help="HTTP address shown in Gremma's receiver settings")
    parser.add_argument("--recorded-at", required=True, help="Actual recording start time, including timezone")
    parser.add_argument("--room", default="Unspecified room")
    parser.add_argument("--timeout", type=float, default=180)
    args = parser.parse_args()
    try:
        result = upload(args.file, args.url, args.recorded_at, args.room, os.environ.get("GREMMA_UPLOAD_TOKEN", ""), args.timeout)
        print(json.dumps(result, sort_keys=True))
        return 0
    except (ValueError, OSError, http.client.HTTPException) as error:
        print(f"Upload failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
