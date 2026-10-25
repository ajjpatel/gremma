package com.gremma.android;

import fi.iki.elonen.NanoHTTPD;
import org.json.JSONObject;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;
import java.security.MessageDigest;
import java.time.Instant;
import java.util.*;
import java.util.concurrent.Semaphore;

/** Receives the board's v1 multipart contract; publishes complete clip directories atomically. */
public final class ClipUploadServer extends NanoHTTPD {
    public interface DirectorySync { void sync(File directory) throws IOException; }
    public interface Listener { void update(String message); }
    public static final long MAX_CLIP_BYTES = 64_000_000;
    private static final long MAX_INBOX_BYTES = 4_000_000_000L;
    private static final long MIN_FREE_BYTES = 512_000_000;
    private final File inbox;
    private final byte[] authorization;
    private final DirectorySync directorySync;
    private final Listener listener;
    private final Semaphore upload = new Semaphore(1);

    public ClipUploadServer(int port, File inbox, File temporaryDirectory, String token,
                            DirectorySync directorySync, Listener listener) throws IOException {
        super(port);
        this.inbox = inbox;
        this.directorySync = directorySync;
        this.listener = listener;
        this.authorization = ("Bearer " + token).getBytes(StandardCharsets.UTF_8);
        if (token.length() < 32) throw new IllegalArgumentException("A pairing token is required");
        if ((!inbox.isDirectory() && !inbox.mkdirs()) ||
                (!temporaryDirectory.isDirectory() && !temporaryDirectory.mkdirs())) {
            throw new IOException("Could not open the clip inbox");
        }
        setTempFileManagerFactory(() -> new TempFileManager() {
            final List<TempFile> files = new ArrayList<>();
            public TempFile createTempFile(String ignored) throws Exception {
                DefaultTempFile file = new DefaultTempFile(temporaryDirectory);
                files.add(file);
                return file;
            }
            public void clear() {
                for (TempFile file : files) try { file.delete(); } catch (Exception ignored) { }
                files.clear();
            }
        });
        // A stalled client must not create an unbounded number of server threads.
        setAsyncRunner(new DefaultAsyncRunner() {
            @Override public synchronized void exec(ClientHandler client) {
                if (getRunning().size() >= 4) client.close();
                else super.exec(client);
            }
        });
    }

    @Override public Response serve(IHTTPSession session) {
        boolean locked = false;
        File staging = null;
        try {
            byte[] supplied = session.getHeaders().getOrDefault("authorization", "").getBytes(StandardCharsets.UTF_8);
            if (!MessageDigest.isEqual(authorization, supplied)) return error(401, "Pairing token does not match");
            if (Method.GET.equals(session.getMethod()) && "/v1/health".equals(session.getUri())) {
                return json(200, new JSONObject().put("schema_version", 1).put("ready", true));
            }
            if (!"/v1/clips".equals(session.getUri())) return error(404, "Unknown endpoint");
            if (!Method.POST.equals(session.getMethod())) return error(405, "Use POST /v1/clips");
            if (session.getHeaders().containsKey("transfer-encoding")) return error(411, "Content-Length is required");
            long bodySize;
            try { bodySize = Long.parseLong(session.getHeaders().getOrDefault("content-length", "")); }
            catch (NumberFormatException e) { return error(411, "Content-Length is required"); }
            if (bodySize <= 0 || bodySize > MAX_CLIP_BYTES + 70_000) return error(413, "Clip exceeds 64 MB");
            if (!session.getHeaders().getOrDefault("content-type", "").startsWith("multipart/form-data;")) {
                return error(415, "Expected multipart metadata and video");
            }
            locked = upload.tryAcquire();
            if (!locked) return error(503, "Another upload is in progress; retry");
            // NanoHTTPD spools the request and its parts; reserve room for those plus the durable copy.
            if (inbox.getUsableSpace() < MIN_FREE_BYTES + 3 * bodySize) return error(507, "Phone storage is full");
            Map<String, String> parts = new HashMap<>();
            session.parseBody(parts);
            // A multipart JSON Content-Type makes NanoHTTPD store metadata as a temporary file.
            String raw = parts.containsKey("metadata") ? readSmall(new File(parts.get("metadata")))
                    : session.getParms().get("metadata");
            if (raw == null || raw.getBytes(StandardCharsets.UTF_8).length > 65_536 || !parts.containsKey("video")) {
                return error(400, "Both metadata JSON and video are required");
            }
            JSONObject meta = new JSONObject(raw);
            String id = meta.getString("clip_id");
            String device = meta.getString("device_id");
            String sha = meta.getString("sha256");
            long size = meta.getLong("size_bytes");
            double duration = meta.getDouble("duration_seconds");
            if (meta.getInt("schema_version") != 1 || !id.matches("[a-f0-9]{32}") ||
                    !device.matches("[A-Za-z0-9_-]{1,64}") || !sha.matches("[a-f0-9]{64}") ||
                    size <= 0 || size > MAX_CLIP_BYTES || !Double.isFinite(duration) || duration <= 0 || duration > 600) {
                return error(400, "Invalid clip metadata");
            }
            long startedAt = Instant.parse(meta.getString("started_at")).toEpochMilli();
            if (!(device + ":" + id).equals(session.getHeaders().get("idempotency-key"))) {
                return error(400, "Idempotency-Key does not match the clip");
            }
            File received = new File(parts.get("video"));
            if (received.length() != size || !sha.equals(sha256(received))) return error(422, "Video checksum or size does not match");
            File target = new File(inbox, device + "_" + id);
            if (target.exists()) {
                JSONObject previous = new JSONObject(readSmall(new File(target, "metadata.json")));
                File video = new File(target, "video.mp4");
                if (!sha.equals(previous.getString("sha256")) || size != previous.getLong("size_bytes") ||
                        !meta.getString("started_at").equals(previous.getString("started_at"))) {
                    return error(409, "This clip ID already has different content");
                }
                if (!video.isFile() || video.length() != size || !sha.equals(sha256(video))) {
                    return error(500, "Saved clip needs recovery");
                }
                directorySync.sync(inbox);
                return json(200, new JSONObject().put("clip_id", id).put("stored", true));
            }
            if (directoryBytes(inbox) + size + raw.length() > MAX_INBOX_BYTES) return error(507, "Clip inbox is full");
            staging = new File(inbox, ".receiving-" + UUID.randomUUID());
            if (!staging.mkdir()) throw new IOException("Could not stage the clip");
            File video = new File(staging, "video.mp4");
            try (InputStream input = new FileInputStream(received); FileOutputStream output = new FileOutputStream(video)) {
                byte[] buffer = new byte[256 * 1024];
                int n;
                while ((n = input.read(buffer)) != -1) output.write(buffer, 0, n);
                if (!video.setLastModified(startedAt)) throw new IOException("Could not preserve capture time");
                output.getFD().sync();
            }
            try (FileOutputStream output = new FileOutputStream(new File(staging, "metadata.json"))) {
                output.write(raw.getBytes(StandardCharsets.UTF_8));
                output.getFD().sync();
            }
            directorySync.sync(staging);
            Files.move(staging.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE);
            staging = null;
            directorySync.sync(inbox);
            listener.update("Clip received. Waiting for processing.");
            return json(201, new JSONObject().put("clip_id", id).put("stored", true));
        } catch (ResponseException e) {
            return error(400, "Invalid multipart upload");
        } catch (org.json.JSONException | java.time.DateTimeException | IllegalArgumentException e) {
            return error(400, "Invalid clip metadata");
        } catch (Exception e) {
            listener.update("Clip could not be saved. The camera will retry.");
            return error(500, "Clip was not acknowledged; retry");
        } finally {
            if (staging != null) deleteStaging(staging);
            if (locked) upload.release();
        }
    }

    private static String readSmall(File file) throws IOException {
        if (!file.isFile() || file.length() > 65_536) throw new IOException("Invalid metadata size");
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        try (InputStream input = new FileInputStream(file)) {
            byte[] buffer = new byte[4096];
            int n;
            while ((n = input.read(buffer)) != -1) {
                if (output.size() + n > 65_536) throw new IOException("Metadata exceeds limit");
                output.write(buffer, 0, n);
            }
        }
        return output.toString(StandardCharsets.UTF_8.name());
    }

    public static String hex(byte[] bytes) {
        StringBuilder result = new StringBuilder(bytes.length * 2);
        for (byte b : bytes) result.append(String.format(Locale.ROOT, "%02x", b & 0xff));
        return result.toString();
    }

    private static String sha256(File file) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        try (InputStream input = new FileInputStream(file)) {
            byte[] buffer = new byte[256 * 1024];
            int n;
            while ((n = input.read(buffer)) != -1) digest.update(buffer, 0, n);
        }
        return hex(digest.digest());
    }

    private static long directoryBytes(File file) {
        if (file.isFile()) return file.length();
        long total = 0;
        File[] children = file.listFiles();
        if (children != null) for (File child : children) total += directoryBytes(child);
        return total;
    }

    private static void deleteStaging(File directory) {
        File[] children = directory.listFiles();
        if (children != null) for (File file : children) file.delete();
        directory.delete();
    }

    private static Response error(int code, String message) {
        try { return json(code, new JSONObject().put("error", message)); }
        catch (org.json.JSONException impossible) { throw new IllegalStateException(impossible); }
    }

    private static Response json(int code, JSONObject body) {
        Response.IStatus status = new Response.IStatus() {
            public int getRequestStatus() { return code; }
            public String getDescription() { return code + (code < 300 ? " OK" : " Error"); }
        };
        Response response = newFixedLengthResponse(status, "application/json", body.toString());
        response.addHeader("Connection", "close");
        return response;
    }
}
