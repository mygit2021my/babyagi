package app.sandbox.gate;

import android.content.Intent;
import android.os.Bundle;
import android.webkit.CookieManager;
import android.webkit.WebView;
import android.widget.Button;
import android.widget.EditText;
import android.widget.TextView;

import androidx.appcompat.app.AppCompatActivity;

import org.json.JSONObject;

import java.io.IOException;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;

public class LoginActivity extends AppCompatActivity {
    static String baseUrl(android.content.Context context) {
        String value = context.getString(R.string.server_base_url).trim();
        while (value.endsWith("/")) {
            value = value.substring(0, value.length() - 1);
        }
        return value;
    }

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        CookieManager cookies = CookieManager.getInstance();
        cookies.setAcceptCookie(true);
        // CookieManager does not load persisted cookies until a WebView exists.
        try {
            new WebView(getApplicationContext());
        } catch (RuntimeException ignored) {
            // The cookie check below still runs; a missing WebView only skips auto-login.
        }
        if (hasSession()) {
            openBrowse();
            return;
        }
        setContentView(R.layout.activity_login);
        EditText username = findViewById(R.id.username);
        EditText password = findViewById(R.id.password);
        TextView error = findViewById(R.id.error);
        Button login = findViewById(R.id.login);
        login.setOnClickListener(view -> {
            error.setText("");
            login.setEnabled(false);
            String user = username.getText().toString();
            String pass = password.getText().toString();
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
        });
    }

    private boolean hasSession() {
        String cookie = CookieManager.getInstance().getCookie(baseUrl(this));
        return cookie != null && cookie.contains("gate_session=");
    }

    private void storeSession(String token, Runnable onFailure) {
        CookieManager cookies = CookieManager.getInstance();
        cookies.setAcceptCookie(true);
        String secure = baseUrl(this).startsWith("https://") ? "; Secure" : "";
        String value = "gate_session=" + token + "; Path=/; SameSite=Lax; Max-Age=604800" + secure;
        cookies.setCookie(baseUrl(this), value, success -> {
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
        HttpURLConnection conn = (HttpURLConnection) new URL(baseUrl(this) + "/login").openConnection();
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
