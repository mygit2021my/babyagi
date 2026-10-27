package app.sandbox.gate;

import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.os.Bundle;
import android.webkit.CookieManager;
import android.webkit.WebView;
import android.widget.Button;
import android.widget.EditText;
import android.widget.TextView;

import androidx.appcompat.app.AppCompatActivity;

import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.regex.Pattern;

public class LoginActivity extends AppCompatActivity {
    private static final Pattern TUNNEL = Pattern.compile("https://[a-z0-9-]+\\.trycloudflare\\.com");
    private static final String PREFS = "gate";
    private static final String ENTRY_KEY = "entry_url";
    private static final String SERVICE_KEY = "service_url";

    private String serviceUrl = "";

    static String normalize(String value) {
        if (value == null) {
            return "";
        }
        String trimmed = value.trim();
        while (trimmed.endsWith("/")) {
            trimmed = trimmed.substring(0, trimmed.length() - 1);
        }
        return trimmed;
    }

    static boolean isTunnel(String value) {
        return value != null && TUNNEL.matcher(value).matches();
    }

    static String entryRoot(String value) {
        String entry = normalize(value);
        if (entry.endsWith("/address")) {
            entry = normalize(entry.substring(0, entry.length() - "/address".length()));
        }
        return entry;
    }

    static String entryUrl(Context context) {
        SharedPreferences prefs = context.getSharedPreferences(PREFS, MODE_PRIVATE);
        String saved = entryRoot(prefs.getString(ENTRY_KEY, ""));
        if (!saved.isEmpty()) {
            return saved;
        }
        return entryRoot(context.getString(R.string.server_base_url));
    }

    static String baseUrl(Context context) {
        String saved = normalize(context.getSharedPreferences(PREFS, MODE_PRIVATE).getString(SERVICE_KEY, ""));
        if (isTunnel(saved)) {
            return saved;
        }
        String entry = entryUrl(context);
        if (isTunnel(entry)) {
            return entry;
        }
        return saved.isEmpty() ? entry : saved;
    }

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        CookieManager cookies = CookieManager.getInstance();
        cookies.setAcceptCookie(true);
        try {
            new WebView(getApplicationContext());
        } catch (RuntimeException ignored) {
            // The cookie check below still runs; a missing WebView only skips auto-login.
        }
        setContentView(R.layout.activity_login);
        EditText entry = findViewById(R.id.entry);
        EditText username = findViewById(R.id.username);
        EditText password = findViewById(R.id.password);
        TextView error = findViewById(R.id.error);
        Button login = findViewById(R.id.login);
        entry.setText(entryUrl(this));
        login.setEnabled(false);
        error.setText("正在获取访问地址");
        resolve(entry.getText().toString(), true);
        login.setOnClickListener(view -> {
            error.setText("");
            login.setEnabled(false);
            resolve(entry.getText().toString(), false);
        });
        username.setEnabled(true);
        password.setEnabled(true);
    }

    private void resolve(String entryValue, boolean openIfSession) {
        EditText entry = findViewById(R.id.entry);
        EditText username = findViewById(R.id.username);
        EditText password = findViewById(R.id.password);
        TextView error = findViewById(R.id.error);
        Button login = findViewById(R.id.login);
        String user = username.getText().toString();
        String pass = password.getText().toString();
        new Thread(() -> {
            String service;
            String problem = "";
            try {
                service = lookup(entryValue);
            } catch (IOException ex) {
                service = null;
                problem = "无法连接入口";
            }
            String resolved = service;
            String failure = problem;
            runOnUiThread(() -> {
                if (isDestroyed()) {
                    return;
                }
                if (!isTunnel(resolved)) {
                    error.setText(failure.isEmpty() ? "没有拿到访问地址" : failure);
                    login.setEnabled(true);
                    return;
                }
                serviceUrl = resolved;
                getSharedPreferences(PREFS, MODE_PRIVATE).edit()
                        .putString(ENTRY_KEY, entryRoot(entry.getText().toString()))
                        .putString(SERVICE_KEY, resolved)
                        .apply();
                if (openIfSession && hasSession(resolved)) {
                    openBrowse();
                    return;
                }
                if (!openIfSession) {
                    signInOnBackground(user, pass);
                    return;
                }
                error.setText("");
                login.setEnabled(true);
            });
        }).start();
    }

    private void signInOnBackground(String user, String pass) {
        TextView error = findViewById(R.id.error);
        Button login = findViewById(R.id.login);
        new Thread(() -> {
            try {
                String token = signIn(user, pass);
                storeSession(token, () -> {
                    error.setText("登录状态没有保存");
                    login.setEnabled(true);
                });
            } catch (Exception ex) {
                runOnUiThread(() -> {
                    if (isDestroyed()) {
                        return;
                    }
                    error.setText(messageFor(ex));
                    login.setEnabled(true);
                });
            }
        }).start();
    }

    private String lookup(String entryValue) throws IOException {
        String entry = entryRoot(entryValue);
        if (isTunnel(entry)) {
            return entry;
        }
        if (entry.isEmpty()) {
            return "";
        }
        HttpURLConnection conn = (HttpURLConnection) new URL(entry + "/address").openConnection();
        conn.setInstanceFollowRedirects(false);
        conn.setConnectTimeout(12000);
        conn.setReadTimeout(12000);
        conn.setRequestMethod("GET");
        int status = conn.getResponseCode();
        if (status != 200) {
            return "";
        }
        String body = readBody(conn).trim();
        if (isTunnel(body)) {
            return body;
        }
        if (body.startsWith("g1.")) {
            try {
                return AddressCrypto.decrypt(getString(R.string.address_key), body);
            } catch (Exception ex) {
                return "";
            }
        }
        return "";
    }

    private static String readBody(HttpURLConnection conn) throws IOException {
        ByteArrayOutputStream buf = new ByteArrayOutputStream();
        byte[] tmp = new byte[256];
        int total = 0;
        try (InputStream in = conn.getInputStream()) {
            int n;
            while ((n = in.read(tmp)) >= 0 && total < 2000) {
                buf.write(tmp, 0, n);
                total += n;
            }
        }
        return buf.toString(StandardCharsets.UTF_8);
    }

    private boolean hasSession(String service) {
        String cookie = CookieManager.getInstance().getCookie(service);
        return cookie != null && cookie.contains("gate_session=");
    }

    private void storeSession(String token, Runnable onFailure) {
        CookieManager cookies = CookieManager.getInstance();
        cookies.setAcceptCookie(true);
        String secure = serviceUrl.startsWith("https://") ? "; Secure" : "";
        String value = "gate_session=" + token + "; Path=/; SameSite=Lax; Max-Age=604800" + secure;
        cookies.setCookie(serviceUrl, value, success -> {
            if (!Boolean.TRUE.equals(success)) {
                runOnUiThread(() -> {
                    if (!isDestroyed()) {
                        onFailure.run();
                    }
                });
                return;
            }
            cookies.flush();
            runOnUiThread(() -> {
                if (!isDestroyed()) {
                    openBrowse();
                }
            });
        });
    }

    private void openBrowse() {
        startActivity(new Intent(this, BrowseActivity.class));
        finish();
    }

    private String messageFor(Exception ex) {
        if (ex instanceof IllegalStateException && ex.getMessage() != null) {
            return ex.getMessage();
        }
        if (ex instanceof IOException) {
            return "无法连接服务器";
        }
        return "登录失败";
    }

    private String signIn(String username, String password) throws Exception {
        HttpURLConnection conn = (HttpURLConnection) new URL(serviceUrl + "/login").openConnection();
        conn.setConnectTimeout(20000);
        conn.setReadTimeout(20000);
        conn.setRequestMethod("POST");
        conn.setDoOutput(true);
        conn.setRequestProperty("Accept", "application/json");
        conn.setRequestProperty("Content-Type", "application/x-www-form-urlencoded");
        byte[] body = ("username=" + URLEncoder.encode(username, "UTF-8")
                + "&password=" + URLEncoder.encode(password, "UTF-8")).getBytes(StandardCharsets.UTF_8);
        try (OutputStream out = conn.getOutputStream()) {
            out.write(body);
        }
        int status = conn.getResponseCode();
        if (status != 200) {
            throw new IllegalStateException("用户名或密码不正确");
        }
        byte[] buf = new byte[8192];
        int n = conn.getInputStream().read(buf);
        if (n < 0) {
            throw new IllegalStateException("登录没有返回结果");
        }
        return new JSONObject(new String(buf, 0, n, StandardCharsets.UTF_8)).getString("token");
    }
}
