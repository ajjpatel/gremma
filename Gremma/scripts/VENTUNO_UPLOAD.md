# Arduino VENTUNO Q → Gremma

Run this uploader on the VENTUNO Q's **Linux side**, using Python 3. It sends a completed MP4/MOV file to the iPhone; it does not configure the board's camera or microphone. Camera connections, drivers, and recording commands depend on the attached hardware. No physical VENTUNO Q transfer has been validated yet.

1. Connect the board and iPhone to the same **trusted private Wi-Fi network**. Keep Gremma open in the foreground.
2. In Gremma, enable the local video receiver and allow Local Network access. Copy its displayed HTTP address and upload token. The receiver is off by default, advertises `_gremma-video._tcp`, and stops when the app leaves the foreground. Re-enabling it may change the port.
3. Save a complete MP4/MOV video on Linux. To remember conversations, the file must contain an audio track. Gremma currently accepts English audio, videos up to 10 minutes, and uploads up to 100 MiB.
4. Put the token in the environment without putting it in shell history:

```bash
read -rsp 'Gremma upload token: ' GREMMA_UPLOAD_TOKEN
export GREMMA_UPLOAD_TOKEN
```

5. Upload using the **actual recording start time**, with its timezone. Replace the example address, timestamp, and filename:

```bash
python3 upload_video.py /path/to/completed-clip.mp4 \
  --url http://192.168.1.20:54321 \
  --recorded-at 2026-10-24T09:00:00-07:00 \
  --room Kitchen
```

The uploader streams the file in 64 KiB pieces and only connects to private addresses. It needs no pip packages. A JSON response containing `"status": "queued"` and a `video_id` means the iPhone saved the video; it does **not** mean E4B indexing finished. Continue processing in Gremma. If an upload disconnects before acknowledgment, check the video library before retrying to avoid importing the same clip twice. There are no automatic retries.

This local API uses **HTTP**, so video and bearer credentials are not encrypted on the network. Use a trusted private network, never public Wi-Fi or router port forwarding. The token is stored in the iPhone Keychain and must not be committed to source control or included in logs. The service requires authentication even for its health check.

## API

`POST /v1/videos` accepts raw video bytes with these headers:

| Header | Requirement |
| --- | --- |
| `Authorization` | `Bearer ` followed by the token shown in Gremma |
| `Content-Type` | `video/mp4` or `video/quicktime` |
| `Content-Length` | Exact byte count, 1–104857600 |
| `X-Recorded-At` | RFC3339 recording start time including timezone |
| `X-Room` | Optional room name, 1–100 printable ASCII characters |

Success is `202 Accepted` with `{"status":"queued","video_id":"…"}` after durable import. `GET /health` uses the same bearer authentication and returns only readiness/API version. Multipart/chunked bodies, duplicate headers, and public source addresses are rejected. The receiver permits two simultaneous requests, with a 30-second idle limit and a five-minute overall limit.
