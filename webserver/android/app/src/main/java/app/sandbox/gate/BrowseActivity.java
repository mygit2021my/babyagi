package app.sandbox.gate;

import android.annotation.SuppressLint;
import android.os.Bundle;
import android.webkit.CookieManager;
import android.webkit.WebResourceRequest;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Button;
import android.widget.EditText;

import androidx.appcompat.app.AppCompatActivity;

import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;

public class BrowseActivity extends AppCompatActivity {
    private WebView web;

    @SuppressLint("SetJavaScriptEnabled")
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_browse);
        EditText address = findViewById(R.id.address);
        Button open = findViewById(R.id.open);
        web = findViewById(R.id.web);
        CookieManager.getInstance().setAcceptCookie(true);
        CookieManager.getInstance().setAcceptThirdPartyCookies(web, true);
        web.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                return false;
            }
        });
        web.getSettings().setJavaScriptEnabled(true);
        web.getSettings().setDomStorageEnabled(true);
        open.setOnClickListener(view -> {
            String target = address.getText().toString().trim();
            if (target.isEmpty()) {
                return;
            }
            String encoded = URLEncoder.encode(target, StandardCharsets.UTF_8);
            web.loadUrl(LoginActivity.baseUrl(this) + "/open?u=" + encoded);
        });
    }

    @Override
    public void onBackPressed() {
        if (web != null && web.canGoBack()) {
            web.goBack();
            return;
        }
        super.onBackPressed();
    }
}
