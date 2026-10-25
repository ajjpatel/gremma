# Proposed Pixel clip receiver contract (v1)

This is a new integration contract, not an API in the current iOS app. The
endpoint path is configurable. The example is `POST /v1/clips` over HTTPS.

## Request

- `Authorization: Bearer <paired-device-token>`
- `Idempotency-Key: <device_id>:<clip_id>`
- `Content-Type: multipart/form-data; boundary=...`
- A streaming request with an explicit `Content-Length`.
- Part `metadata`: JSON, `application/json`.
- Part `video`: binary `video/mp4`, filename `<clip_id>.mp4` (H.264).

```json
{
  "schema_version": 1,
  "clip_id": "f7242d52c8bd4bc68118b4a0fa69bd87",
  "device_id": "oracle-01",
  "started_at": "2026-10-24T21:00:00+00:00",
  "duration_seconds": 30.0,
  "timing_quality": "capture_clock",
  "size_bytes": 15000000,
  "sha256": "<64 lowercase hex characters>",
  "selection": {
    "candidate": true,
    "send": true,
    "reasons": ["endpoint_change"],
    "method": "first_last_frame_embeddings",
    "cosine_distance": 0.12,
    "difference_threshold": 0.08,
    "frames": {"decoded_frames": 900, "first_frame_seconds": 0, "last_frame_seconds": 29.9667},
    "model_revision": "<downloaded model commit SHA>",
    "error": null
  }
}
```

`timing_quality` is `capture_clock`, `recovered_estimate`, or `import_time`.
The board clock should be synchronized before use. Segments have separate MP4
timelines; use metadata for their relationship to wall time. Segment duration
can vary with keyframe boundaries. Sort by capture time, not arrival order.

Changed clips have reason `endpoint_change`. Failed comparisons are forwarded
with `analysis_unavailable` and an error type. `endpoints_similar` clips stay in
the local ring and are not queued for upload. Frame timestamps are relative to
the MP4 timeline; no intermediate-frame motion or cross-clip comparison is used.
Scores are diagnostics, not probabilities or event labels.

## Response and retries

After validating the token, size and SHA-256 and **durably storing** the bytes
and metadata, respond with HTTP 200 or 201 and:

```json
{"clip_id": "f7242d52c8bd4bc68118b4a0fa69bd87", "stored": true}
```

Deduplicate on `(device_id, clip_id)` and return the same acknowledgement when a
retry contains the same checksum. Reject conflicting content for an existing
ID. The uploader retries failures with exponential backoff capped at five
minutes. It requires a matching JSON acknowledgement, not just HTTP success;
a timeout after storage can therefore produce a duplicate request.

The sender verifies TLS (optionally against `upload_ca_file`), never follows
redirects, and reads the token from the configured environment variable. The
receiver's pairing/token issuance and Android background service are the Pixel
app's responsibility. HTTP and disabled certificate verification are unsupported.

The board ring is finite: a prolonged outage can evict queued clips. Sequence
coverage is not guaranteed. Retention loss is currently available through the
board's `status` command, not a pushed alert. An absence of clips/events must
not be interpreted as proof that an activity did not occur.
