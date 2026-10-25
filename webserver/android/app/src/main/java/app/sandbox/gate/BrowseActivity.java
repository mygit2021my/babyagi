package app.sandbox.gate;

import android.annotation.SuppressLint;
import android.os.Bundle;
import android.webkit.CookieManager;
import android.webkit.WebView;

import androidx.appcompat.app.AppCompatActivity;

public class BrowseActivity extends AppCompatActivity {
    private WebView web;

    @SuppressLint("SetJavaScriptEnabled")
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_browse);
        web = findViewById(R.id.web);
        CookieManager.getInstance().setAcceptCookie(true);
        CookieManager.getInstance().setAcceptThirdPartyCookies(web, true);
        web.getSettings().setJavaScriptEnabled(true);
        web.getSettings().setDomStorageEnabled(true);
        web.loadUrl(LoginActivity.baseUrl(this) + "/");
    }
}
