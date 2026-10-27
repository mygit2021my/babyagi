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
        if (entry.isEmpty()) {
            return "";
        }
        if (!entry.startsWith("http://") && !entry.startsWith("https://")) {
            entry = "http://" + entry;
        }
        int cut = entry.indexOf('?');
        if (cut >= 0) {
            entry = entry.substring(0, cut);
        }
        cut = entry.indexOf('#');
        if (cut >= 0) {
            entry = entry.substring(0, cut);
        }
        entry = normalize(entry);
        if (entry.endsWith("/address")) {
            entry = normalize(entry.substring(0, entry.length() - "/address".length()));
        }
        return entry;
    }

    static String baseUrl(Context context) {
        String saved = normalize(context.getSharedPreferences(PREFS, MODE_PRIVATE).getString(SERVICE_KEY, ""));
        return isTunnel(saved) ? saved : "";
    }

    static String savedEntry(Context context) {
        return entryRoot(context.getSharedPreferences(PREFS, MODE_PRIVATE).getString(ENTRY_KEY, ""));
    }

    static void clearService(Context context) {
        context.getSharedPreferences(PREFS, MODE_PRIVATE).edit().remove(SERVICE_KEY).apply();
    }

    static boolean tunnelAnswers(String service, int attempts) {
        for (int attempt = 0; attempt < attempts; attempt++) {
            HttpURLConnection conn = null;
            try {
                conn = (HttpURLConnection) new URL(service + "/login").openConnection();
                conn.setInstanceFollowRedirects(true);
                conn.setConnectTimeout(15000);
                conn.setReadTimeout(15000);
                conn.setRequestMethod("GET");
                if (conn.getResponseCode() == 200) {
                    return true;
                }
            } catch (IOException ex) {
                // A slow link often fails the first attempt. Try once more.
            } finally {
                if (conn != null) {
                    conn.disconnect();
                }
            }
        }
        return false;
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
        String remembered = savedEntry(this);
        if (!remembered.isEmpty() && !isTunnel(remembered)) {
            entry.setText(remembered);
        }
        login.setEnabled(true);
        login.setOnClickListener(view -> {
            error.setText("");
            login.setEnabled(false);
            resolve(entry.getText().toString());
        });
        username.setEnabled(true);
        password.setEnabled(true);
        boolean fromBrowse = getIntent().getBooleanExtra("browse_failed", false);
        String existing = baseUrl(this);
        if (fromBrowse) {
            if (remembered.isEmpty() || isTunnel(remembered)) {
                error.setText("页面没有打开，请填写入口");
                return;
            }
            login.setEnabled(false);
            error.setText("正在重新获取访问地址");
            new Thread(() -> refreshAfterFailure(existing, remembered, true)).start();
            return;
        }
        if (!isTunnel(existing) || !hasSession(existing)) {
            return;
        }
        login.setEnabled(false);
        error.setText("正在连接");
        new Thread(() -> {
            boolean ok = tunnelAnswers(existing, 1);
            runOnUiThread(() -> {
                if (isDestroyed()) {
                    return;
                }
                if (ok) {
                    serviceUrl = existing;
                    openBrowse();
                    return;
                }
                String entryValue = savedEntry(LoginActivity.this);
                if (entryValue.isEmpty() || isTunnel(entryValue)) {
                    clearService(LoginActivity.this);
                    error.setText("访问地址已失效，请填写入口");
                    login.setEnabled(true);
                    return;
                }
                error.setText("正在重新获取访问地址");
                new Thread(() -> refreshAfterFailure(existing, entryValue, false)).start();
            });
        }).start();
    }

    private void refreshAfterFailure(String previous, String entryValue, boolean fromBrowse) {
        String service = "";
        String problem = "无法连接入口";
        try {
            service = lookup(entryValue);
            problem = "";
        } catch (IOException ex) {
            service = "";
        }
        boolean live = isTunnel(service) && tunnelAnswers(service, 2);
        String resolved = service;
        String failure = problem;
        runOnUiThread(() -> applyRefresh(previous, entryValue, resolved, failure, live, fromBrowse));
    }

    private void applyRefresh(String previous, String entryValue, String service, String failure, boolean live, boolean fromBrowse) {
        if (isDestroyed()) {
            return;
        }
        EditText entry = findViewById(R.id.entry);
        TextView error = findViewById(R.id.error);
        Button login = findViewById(R.id.login);
        String root = entryRoot(entryValue);
        if (!root.isEmpty() && !isTunnel(root)) {
            entry.setText(root);
            getSharedPreferences(PREFS, MODE_PRIVATE).edit().putString(ENTRY_KEY, root).apply();
        }
        if (!isTunnel(service)) {
            error.setText(failure.isEmpty() ? "没有拿到访问地址" : failure);
            login.setEnabled(true);
            return;
        }
        serviceUrl = service;
        getSharedPreferences(PREFS, MODE_PRIVATE).edit().putString(SERVICE_KEY, service).apply();
        if (!live) {
            error.setText("暂时连不上访问地址");
            login.setEnabled(true);
            return;
        }
        boolean same = service.equals(previous);
        if (hasSession(service) && !(fromBrowse && same)) {
            openBrowse();
            return;
        }
        if (fromBrowse && same) {
            error.setText("页面没有打开，请再登录一次");
        } else if (!same) {
            error.setText("访问地址已更新，请重新登录");
        } else {
            error.setText("请重新登录");
        }
        login.setEnabled(true);
    }

    private void resolve(String entryValue) {
        EditText username = findViewById(R.id.username);
        EditText password = findViewById(R.id.password);
        TextView error = findViewById(R.id.error);
        Button login = findViewById(R.id.login);
        String root = entryRoot(entryValue);
        if (root.isEmpty()) {
            error.setText("请填写入口地址");
            login.setEnabled(true);
            return;
        }
        String user = username.getText().toString();
        String pass = password.getText().toString();
        new Thread(() -> {
            String service;
            String problem = "";
            try {
                service = lookup(root);
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
                SharedPreferences.Editor editor = getSharedPreferences(PREFS, MODE_PRIVATE).edit()
                        .putString(SERVICE_KEY, resolved);
                if (!isTunnel(root)) {
                    editor.putString(ENTRY_KEY, root);
                }
                editor.apply();
                signInOnBackground(user, pass);
            });
        }).start();
    }

    private void signInOnBackground(String user, String pass) {
        TextView error = findViewById(R.id.error);
        Button login = findViewById(R.id.login);
        new Thread(() -> {
            try {
                String token = signIn(user, pass);
                runOnUiThread(() -> {
                    if (isDestroyed()) {
                        return;
                    }
                    storeSession(token, () -> {
                        error.setText("登录状态没有保存");
                        login.setEnabled(true);
                    });
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
        conn.setConnectTimeout(15000);
        conn.setReadTimeout(15000);
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
        conn.setReadTimeout(25000);
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
