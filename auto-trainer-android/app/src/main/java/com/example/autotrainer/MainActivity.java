package com.example.autotrainer;

import android.app.Activity;
import android.content.*;
import android.media.projection.MediaProjectionManager;
import android.os.Bundle;
import android.provider.Settings;
import android.widget.*;

public class MainActivity extends Activity {
    static final int CAPTURE=1001; private TextView status;
    @Override public void onCreate(Bundle b){
        super.onCreate(b);
        LinearLayout box=new LinearLayout(this);box.setOrientation(LinearLayout.VERTICAL);box.setPadding(28,28,28,28);
        TextView title=new TextView(this);title.setText("Auto Trainer — Karmis Visual Loop");title.setTextSize(23);box.addView(title);
        status=new TextView(this);status.setText("Кадры → локальное состояние → +/−. Без облачного запроса в горячем цикле.");box.addView(status);
        Button acc=new Button(this);acc.setText("1. Включить Accessibility");acc.setOnClickListener(v->startActivity(new Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)));box.addView(acc);
        Button capture=new Button(this);capture.setText("2. Разрешить просмотр экрана");capture.setOnClickListener(v->{MediaProjectionManager m=(MediaProjectionManager)getSystemService(MEDIA_PROJECTION_SERVICE);
            startActivityForResult(m.createScreenCaptureIntent(),CAPTURE);});box.addView(capture);
        Button stand=new Button(this);stand.setText("Цель: СТОЯТЬ");stand.setOnClickListener(v->{TrainerController.setGoal(this,"stand");status.setText("Цель: СТОЯТЬ");});box.addView(stand);
        Button walk=new Button(this);walk.setText("Цель: ИДТИ");walk.setOnClickListener(v->{TrainerController.setGoal(this,"walk");status.setText("Цель: ИДТИ");});box.addView(walk);
        Button stop=new Button(this);stop.setText("Остановить");stop.setOnClickListener(v->stopService(new Intent(this,ScreenCaptureService.class)));box.addView(stop);
        TextView note=new TextView(this);note.setText("Захват идёт через системный MediaProjection, действия — через Accessibility. Анализ использует маленький grayscale-кадр и берёт последний доступный кадр, чтобы не копить очередь.");box.addView(note);
        setContentView(box);
    }
    @Override protected void onActivityResult(int r,int c,Intent d){super.onActivityResult(r,c,d);
        if(r==CAPTURE&&c==RESULT_OK&&d!=null){Intent i=new Intent(this,ScreenCaptureService.class);i.putExtra("resultCode",c);i.putExtra("data",d);
            startForegroundService(i);status.setText("Захват запущен");}}
}
