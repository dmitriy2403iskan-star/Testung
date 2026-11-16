package com.example.autotrainer;

import android.accessibilityservice.AccessibilityServiceInfo;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.os.Bundle;
import android.provider.Settings;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;

public class MainActivity extends android.app.Activity {
    private TextView status;
    private static final String PREFS = "trainer";

    @Override public void onCreate(Bundle b) {
        super.onCreate(b);
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(32, 40, 32, 32);

        TextView title = new TextView(this);
        title.setText("Auto Trainer\nВнешний тренер");
        title.setTextSize(24);
        root.addView(title, new LinearLayout.LayoutParams(-1, -2));

        status = new TextView(this);
        status.setTextSize(16);
        status.setPadding(0, 24, 0, 24);
        root.addView(status, new LinearLayout.LayoutParams(-1, -2));

        Button settings = new Button(this);
        settings.setText("1. Включить Accessibility Service");
        settings.setOnClickListener(v -> startActivity(new Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)));
        root.addView(settings, new LinearLayout.LayoutParams(-1, -2));

        Button start = new Button(this);
        start.setText("2. Запустить автотренировку");
        start.setOnClickListener(v -> {
            getSharedPreferences(PREFS, MODE_PRIVATE).edit().putBoolean("running", true).apply();
            TrainerAccessibilityService.requestRefresh();
            updateStatus();
        });
        root.addView(start, new LinearLayout.LayoutParams(-1, -2));

        Button stop = new Button(this);
        stop.setText("Остановить");
        stop.setOnClickListener(v -> {
            getSharedPreferences(PREFS, MODE_PRIVATE).edit().putBoolean("running", false).apply();
            updateStatus();
        });
        root.addView(stop, new LinearLayout.LayoutParams(-1, -2));

        Button reset = new Button(this);
        reset.setText("Сбросить серию");
        reset.setOnClickListener(v -> {
            getSharedPreferences(PREFS, MODE_PRIVATE).edit().putInt("streak", 0).apply();
            updateStatus();
        });
        root.addView(reset, new LinearLayout.LayoutParams(-1, -2));

        setContentView(root);
        updateStatus();
    }

    @Override protected void onResume() {
        super.onResume();
        updateStatus();
    }

    private void updateStatus() {
        boolean enabled = false;
        String expected = new ComponentName(this, TrainerAccessibilityService.class).flattenToString();
        for (AccessibilityServiceInfo i : ((android.view.accessibility.AccessibilityManager)getSystemService(Context.ACCESSIBILITY_SERVICE)).getEnabledAccessibilityServiceList(AccessibilityServiceInfo.FEEDBACK_ALL_MASK)) {
            if (expected.equals(i.getResolveInfo().serviceInfo.packageName + "/" + i.getResolveInfo().serviceInfo.name)) {
                enabled = true; break;
            }
        }
        boolean running = getSharedPreferences(PREFS, MODE_PRIVATE).getBoolean("running", false);
        int streak = getSharedPreferences(PREFS, MODE_PRIVATE).getInt("streak", 0);
        status.setText("Сервис: " + (enabled ? "включён" : "не включён") +
                "\nАвтотренировка: " + (running ? "запущена" : "остановлена") +
                "\nУспешная серия: " + streak + "/10" +
                "\nЦель: приложение com.example.komandir");
    }
}
