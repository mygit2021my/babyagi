package app.sandbox.gate;

import android.content.Intent;
import android.os.Bundle;
import android.webkit.CookieManager;
import android.widget.Button;
import android.widget.EditText;
import android.widget.TextView;

import androidx.appcompat.app.AppCompatActivity;

import org.json.JSONObject;

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
                    CookieManager cookies = CookieManager.getInstance();
                    cookies.setAcceptCookie(true);
                    cookies.setCookie(baseUrl(this), "gate_session=" + token + "; Path=/; Secure");
                    cookies.flush();
                    runOnUiThread(() -> {
                        startActivity(new Intent(this, BrowseActivity.class));
                        finish();
                    });
                } catch (Exception ex) {
                    runOnUiThread(() -> {
                        error.setText(ex.getMessage() == null ? "登录失败" : ex.getMessage());
                        login.setEnabled(true);
                    });
                }
            }).start();
        });
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
