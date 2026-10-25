package app.sandbox.gate;

import android.util.Base64;

import java.nio.charset.StandardCharsets;

import javax.crypto.Cipher;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;

final class AddressCrypto {
    private AddressCrypto() {}

    static String decrypt(String keyHex, String blob) throws Exception {
        String value = blob == null ? "" : blob.trim();
        if (!value.startsWith("g1.")) {
            throw new IllegalArgumentException("blob");
        }
        byte[] raw = Base64.decode(value.substring(3), Base64.URL_SAFE | Base64.NO_PADDING | Base64.NO_WRAP);
        if (raw.length < 28) {
            throw new IllegalArgumentException("short");
        }
        byte[] key = hex(keyHex == null ? "" : keyHex.trim().toLowerCase());
        byte[] nonce = new byte[12];
        System.arraycopy(raw, 0, nonce, 0, 12);
        byte[] sealed = new byte[raw.length - 12];
        System.arraycopy(raw, 12, sealed, 0, sealed.length);
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.DECRYPT_MODE, new SecretKeySpec(key, "AES"), new GCMParameterSpec(128, nonce));
        String url = new String(cipher.doFinal(sealed), StandardCharsets.UTF_8);
        if (!url.matches("https://[a-z0-9-]+\\.trycloudflare\\.com")) {
            throw new IllegalArgumentException("url");
        }
        return url;
    }

    private static byte[] hex(String hex) {
        if (!hex.matches("[0-9a-f]{64}")) {
            throw new IllegalArgumentException("key");
        }
        byte[] out = new byte[32];
        for (int i = 0; i < 32; i++) {
            out[i] = (byte) Integer.parseInt(hex.substring(i * 2, i * 2 + 2), 16);
        }
        return out;
    }
}
