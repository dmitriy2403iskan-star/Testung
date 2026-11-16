package com.example.autotrainer;

import android.accessibilityservice.AccessibilityService;
import android.view.accessibility.AccessibilityEvent;
import android.view.accessibility.AccessibilityNodeInfo;
import android.os.Handler;
import android.os.Looper;
import android.content.Intent;
import android.net.Uri;
import android.provider.Settings;
import java.io.OutputStream;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.Locale;
import android.content.ContentValues;

public class TrainerAccessibilityService extends AccessibilityService {
    private static final String TARGET = "com.example.komandir";
    private static final String PREFS = "trainer";
    private static TrainerAccessibilityService instance;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private long lastDecision = 0;

    public static void requestRefresh() {
        if (instance != null) instance.scan();
    }

    @Override public void onServiceConnected() {
        super.onServiceConnected();
        instance = this;
        scan();
    }

    @Override public void onDestroy() {
        instance = null;
        super.onDestroy();
    }

    @Override public void onAccessibilityEvent(AccessibilityEvent event) {
        if (!getSharedPreferences(PREFS, MODE_PRIVATE).getBoolean("running", false)) return;
        if (event.getPackageName() == null || !TARGET.contentEquals(event.getPackageName())) return;
        handler.removeCallbacksAndMessages(null);
        handler.postDelayed(this::scan, 180);
    }

    @Override public void onInterrupt() {}

    private void scan() {
        if (!getSharedPreferences(PREFS, MODE_PRIVATE).getBoolean("running", false)) return;
        AccessibilityNodeInfo root = getRootInActiveWindow();
        if (root == null) return;

        StringBuilder text = new StringBuilder();
        collectText(root, text);
        String screen = text.toString().toLowerCase(Locale.ROOT);

        if (containsAny(screen, "упал", "падение", "ошибка", "неудача", "failed", "fall", "failure", "minus")) {
            decide(false);
            return;
        }
        if (containsAny(screen, "успех", "успешно", "молодец", "готово", "success", "passed", "standing", "walk complete", "plus")) {
            decide(true);
            return;
        }

        // If the UI exposes a "next/restart/start" button, press it only after a decision.
        if (System.currentTimeMillis() - lastDecision > 2500) {
            clickText(root, "Начать");
            clickText(root, "Новая попытка");
            clickText(root, "Start");
            clickText(root, "Restart");
            lastDecision = System.currentTimeMillis();
        }
    }

    private void decide(boolean success) {
        long now = System.currentTimeMillis();
        if (now - lastDecision < 1200) return;
        lastDecision = now;

        android.content.SharedPreferences p = getSharedPreferences(PREFS, MODE_PRIVATE);
        int streak = success ? p.getInt("streak", 0) + 1 : 0;
        int total = p.getInt("total", 0) + 1;
        p.edit().putInt("streak", streak).putInt("total", total).apply();

        if (success && streak >= 10) {
            exportSkill(streak, total);
            p.edit().putInt("streak", 0).apply();
        }

        AccessibilityNodeInfo root = getRootInActiveWindow();
        if (root != null) {
            if (success) {
                clickText(root, "Дальше");
                clickText(root, "Next");
                clickText(root, "Продолжить");
                clickText(root, "Continue");
            } else {
                clickText(root, "Повторить");
                clickText(root, "Retry");
                clickText(root, "Начать");
                clickText(root, "Start");
            }
        }
    }

    private void collectText(AccessibilityNodeInfo n, StringBuilder out) {
        if (n == null) return;
        CharSequence t = n.getText();
        CharSequence d = n.getContentDescription();
        if (t != null) out.append(' ').append(t);
        if (d != null) out.append(' ').append(d);
        for (int i = 0; i < n.getChildCount(); i++) collectText(n.getChild(i), out);
    }

    private boolean clickText(AccessibilityNodeInfo root, String wanted) {
        java.util.List<AccessibilityNodeInfo> nodes = root.findAccessibilityNodeInfosByText(wanted);
        for (AccessibilityNodeInfo n : nodes) {
            if (n.isClickable() && n.performAction(AccessibilityNodeInfo.ACTION_CLICK)) return true;
            AccessibilityNodeInfo parent = n.getParent();
            if (parent != null && parent.isClickable() && parent.performAction(AccessibilityNodeInfo.ACTION_CLICK)) return true;
        }
        return false;
    }

    private boolean containsAny(String s, String... keys) {
        for (String k : keys) if (s.contains(k)) return true;
        return false;
    }

    private void exportSkill(int streak, int total) {
        try {
            String stamp = new SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(new Date());
            String json = "{\n" +
                    "  \"format\": \"auto-trainer-skill-v1\",\n" +
                    "  \"source_app\": \"" + TARGET + "\",\n" +
                    "  \"success_streak\": " + streak + ",\n" +
                    "  \"episodes\": " + total + ",\n" +
                    "  \"created_at\": \"" + stamp + "\"\n" +
                    "}\n";

            ContentValues v = new ContentValues();
            v.put(android.provider.MediaStore.Downloads.DISPLAY_NAME, "skill_" + stamp + ".json");
            v.put(android.provider.MediaStore.Downloads.MIME_TYPE, "application/json");
            v.put(android.provider.MediaStore.Downloads.RELATIVE_PATH, "Download/AutoTrainer");
            Uri uri = getContentResolver().insert(android.provider.MediaStore.Downloads.EXTERNAL_CONTENT_URI, v);
            if (uri != null) {
                OutputStream os = getContentResolver().openOutputStream(uri);
                if (os != null) { os.write(json.getBytes(java.nio.charset.StandardCharsets.UTF_8)); os.close(); }
            }
        } catch (Exception ignored) {}
    }
}
