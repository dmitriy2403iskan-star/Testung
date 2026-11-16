package com.example.autotrainer;

import android.app.Activity;
import android.content.Intent;
import android.media.projection.MediaProjectionManager;
import android.os.Bundle;
import android.provider.Settings;
import android.widget.*;

public class MainActivity extends Activity {
    static final int CAPTURE=1001;
    @Override public void onCreate(Bundle b){
        super.onCreate(b);
        LinearLayout box=new LinearLayout(this); box.setOrientation(LinearLayout.VERTICAL); box.setPadding(32,32,32,32);
        TextView title=new TextView(this); title.setText("Auto Trainer\nЗрительный режим"); title.setTextSize(24); box.addView(title);
        TextView info=new TextView(this); info.setText("Приложение смотрит на экран Testung через системный MediaProjection, оценивает состояние персонажа по последовательности кадров и передаёт результат тренеру. Никаких скрытых захватов: Android показывает разрешение на захват экрана."); box.addView(info);
        Button acc=new Button(this); acc.setText("1. Включить Accessibility"); acc.setOnClickListener(v->startActivity(new Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))); box.addView(acc);
        Button capture=new Button(this); capture.setText("2. Разрешить просмотр экрана"); capture.setOnClickListener(v->{ MediaProjectionManager m=(MediaProjectionManager)getSystemService(MEDIA_PROJECTION_SERVICE); startActivityForResult(m.createScreenCaptureIntent(),CAPTURE); }); box.addView(capture);
        Button stop=new Button(this); stop.setText("Остановить просмотр"); stop.setOnClickListener(v->stopService(new Intent(this,ScreenCaptureService.class))); box.addView(stop);
        setContentView(box);
    }
    @Override protected void onActivityResult(int r,int c,Intent d){
        super.onActivityResult(r,c,d);
        if(r==CAPTURE && c==RESULT_OK && d!=null){
            Intent i=new Intent(this,ScreenCaptureService.class);
            i.putExtra("resultCode",c); i.putExtra("data",d);
            startForegroundService(i);
        }
    }
}