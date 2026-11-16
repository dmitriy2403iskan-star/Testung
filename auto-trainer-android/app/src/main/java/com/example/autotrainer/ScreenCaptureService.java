package com.example.autotrainer;

import android.app.*;
import android.content.*;
import android.graphics.*;
import android.hardware.display.*;
import android.media.*;
import android.media.projection.*;
import android.os.*;
import java.nio.*;
import java.util.*;

public class ScreenCaptureService extends Service {
    private MediaProjection projection;
    private ImageReader reader;
    private VirtualDisplay display;
    private HandlerThread thread;
    private Handler handler;
    private long lastFrame=0;
    private Bitmap previous;
    private float motionEma=0f;

    @Override public int onStartCommand(Intent intent,int flags,int id){
        createChannel();
        startForeground(77, notification());
        int code=intent.getIntExtra("resultCode",-1);
        Intent data=intent.getParcelableExtra("data");
        if(code!=Activity.RESULT_OK || data==null){ stopSelf(); return START_NOT_STICKY; }
        MediaProjectionManager pm=(MediaProjectionManager)getSystemService(MEDIA_PROJECTION_SERVICE);
        projection=pm.getMediaProjection(code,data);
        DisplayMetricsCompat metrics=new DisplayMetricsCompat(this);
        thread=new HandlerThread("screen-capture"); thread.start(); handler=new Handler(thread.getLooper());
        reader=ImageReader.newInstance(metrics.w,metrics.h,PixelFormat.RGBA_8888,2);
        reader.setOnImageAvailableListener(r->analyze(r.acquireLatestImage()),handler);
        display=projection.createVirtualDisplay("AutoTrainerCapture",metrics.w,metrics.h,metrics.dpi,DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,reader.getSurface(),null,handler);
        return START_NOT_STICKY;
    }

    private void analyze(Image image){
        if(image==null) return;
        try{
            Image.Plane p=image.getPlanes()[0];
            ByteBuffer b=p.getBuffer();
            int w=image.getWidth(),h=image.getHeight();
            Bitmap cur=Bitmap.createBitmap(w,h,Bitmap.Config.ARGB_8888);
            cur.copyPixelsFromBuffer(b);
            Bitmap small=Bitmap.createScaledBitmap(cur,96,Math.max(1,(int)(96f*h/w)),true);
            if(previous!=null){
                float diff=0;
                int samples=0;
                for(int y=0;y<small.getHeight();y+=3) for(int x=0;x<small.getWidth();x+=3){
                    int a=small.getPixel(x,y), q=previous.getPixel(x,y);
                    diff += Math.abs(Color.red(a)-Color.red(q))+Math.abs(Color.green(a)-Color.green(q))+Math.abs(Color.blue(a)-Color.blue(q));
                    samples++;
                }
                float motion=diff/(samples*765f);
                motionEma=motionEma*0.8f+motion*0.2f;
                // This is the visual observation layer. It deliberately does not claim that
                // motion alone means "fall"; the next classifier consumes frame sequences.
                TrainerStateStore.recordFrame(System.currentTimeMillis(),motionEma);
            }
            previous=small;
            cur.recycle();
        }finally{ image.close(); }
    }

    private Notification notification(){
        return new Notification.Builder(this,"trainer").setContentTitle("Auto Trainer").setContentText("Просмотр экрана активен").setSmallIcon(android.R.drawable.ic_menu_view).build();
    }
    private void createChannel(){
        if(Build.VERSION.SDK_INT>=26)((NotificationManager)getSystemService(NOTIFICATION_SERVICE)).createNotificationChannel(new NotificationChannel("trainer","Auto Trainer",NotificationManager.IMPORTANCE_LOW));
    }
    @Override public void onDestroy(){ if(display!=null)display.release(); if(projection!=null)projection.stop(); if(reader!=null)reader.close(); if(thread!=null)thread.quitSafely(); super.onDestroy(); }
    @Override public android.os.IBinder onBind(Intent i){return null;}
    static class DisplayMetricsCompat {
        int w,h,dpi;
        DisplayMetricsCompat(Context c){ android.util.DisplayMetrics m=c.getResources().getDisplayMetrics(); w=m.widthPixels; h=m.heightPixels; dpi=m.densityDpi; }
    }
}