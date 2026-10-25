import com.gremma.android.ClipUploadServer;
import java.io.*;
import java.nio.channels.FileChannel;
import java.nio.file.StandardOpenOption;
import java.security.KeyStore;
import javax.net.ssl.KeyManagerFactory;
import javax.net.ssl.SSLContext;

/** Runs the unchanged Android receiver on a JVM; no Android emulator or model is needed. */
public final class ReceiverHarness {
    public static void main(String[] args) throws Exception {
        KeyStore keys = KeyStore.getInstance("PKCS12");
        try (InputStream input = new FileInputStream(args[1])) { keys.load(input, "test-password".toCharArray()); }
        KeyManagerFactory managers = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
        managers.init(keys, "test-password".toCharArray());
        SSLContext tls = SSLContext.getInstance("TLS");
        tls.init(managers.getKeyManagers(), null, null);
        File root = new File(args[0]);
        ClipUploadServer server = new ClipUploadServer(0, new File(root, "inbox"), new File(root, "temporary"),
                "test-token-0123456789abcdef0123456789abcdef", directory -> {
                    try (FileChannel channel = FileChannel.open(directory.toPath(), StandardOpenOption.READ)) { channel.force(true); }
                }, message -> { });
        server.makeSecure(tls.getServerSocketFactory(), new String[]{"TLSv1.2", "TLSv1.3"});
        server.start(3000, true);
        System.out.println("READY:" + server.getListeningPort());
        System.out.flush();
        try { System.in.read(); } finally { server.stop(); }
    }
}
