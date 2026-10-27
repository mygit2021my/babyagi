package app.sandbox.gate;

import android.annotation.SuppressLint;
import android.content.Intent;
import android.os.Bundle;
import android.webkit.CookieManager;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebView;
import android.webkit.WebViewClient;

import androidx.activity.OnBackPressedCallback;
import androidx.appcompat.app.AppCompatActivity;

public class BrowseActivity extends AppCompatActivity {
    private WebView web;
    private boolean retried;

    @SuppressLint("SetJavaScriptEnabled")
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_browse);
        web = findViewById(R.id.web);
        CookieManager cookies = CookieManager.getInstance();
        cookies.setAcceptCookie(true);
        cookies.setAcceptThirdPartyCookies(web, true);
        web.getSettings().setJavaScriptEnabled(true);
        web.getSettings().setDomStorageEnabled(true);
        web.getSettings().setUseWideViewPort(true);
        web.getSettings().setLoadWithOverviewMode(false);
        web.getSettings().setSupportZoom(false);
        web.getSettings().setBuiltInZoomControls(false);
        web.getSettings().setMediaPlaybackRequiresUserGesture(false);
        web.getSettings().setTextZoom(100);
        web.setInitialScale(100);
        web.setWebViewClient(new WebViewClient() {
            @Override
            public void onReceivedError(WebView view, WebResourceRequest request, WebResourceError error) {
                if (!request.isForMainFrame() || isFinishing()) {
                    return;
                }
                if (!retried) {
                    retried = true;
                    view.postDelayed(() -> {
                        if (!isFinishing() && web != null) {
                            web.reload();
                        }
                    }, 800);
                    return;
                }
                Intent intent = new Intent(BrowseActivity.this, LoginActivity.class);
                intent.putExtra("browse_failed", true);
                intent.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP);
                startActivity(intent);
                finish();
            }
        });
        String agent = web.getSettings().getUserAgentString();
        if (agent == null || agent.isEmpty()) {
            agent = "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/156.0.0.0 Mobile Safari/537.36";
        }
        if (!agent.contains("GateAndroid")) {
            agent = agent + " GateAndroid";
        }
        web.getSettings().setUserAgentString(agent);
        getOnBackPressedDispatcher().addCallback(this, new OnBackPressedCallback(true) {
            @Override
            public void handleOnBackPressed() {
                if (web != null && web.canGoBack()) {
                    web.goBack();
                    return;
                }
                setEnabled(false);
                getOnBackPressedDispatcher().onBackPressed();
            }
        });
        String page = LoginActivity.baseUrl(this);
        if (!LoginActivity.isTunnel(page)) {
            finish();
            return;
        }
        web.loadUrl(page + "/");
    }

    @Override
    protected void onDestroy() {
        if (web != null) {
            web.destroy();
            web = null;
        }
        super.onDestroy();
    }
}
