package com.example.autotrainer;

import android.app.*;
import android.content.*;
import android.graphics.PixelFormat;
import android.hardware.display.*;
import android.media.*;
import android.media.projection.*;
import android.os.*;
import java.nio.ByteBuffer;

public class ScreenCaptureService extends Service {
    private MediaProjection projection; private ImageReader reader; private VirtualDisplay display;
    private HandlerThread thread; private Handler handler; private VisualObserver observer;

    @Override public int onStartCommand(Intent intent,int flags,int id){
        createChannel();startForeground(77,notification());
        int code=intent.getIntExtra("resultCode",-1);Intent data=intent.getParcelableExtra("data");
        if(code!=Activity.RESULT_OK||data==null){stopSelf();return START_NOT_STICKY;}
        MediaProjectionManager pm=(MediaProjectionManager)getSystemService(MEDIA_PROJECTION_SERVICE);
        projection=pm.getMediaProjection(code,data);
        projection.registerCallback(new MediaProjection.Callback(){@Override public void onStop(){stopSelf();}},
                new Handler(Looper.getMainLooper()));
        DisplayMetricsCompat m=new DisplayMetricsCompat(this);
        int aw=96,ah=Math.max(54,Math.round(aw*m.h/(float)m.w));
        observer=new VisualObserver(aw,ah);
        thread=new HandlerThread("auto-trainer-vision",Process.THREAD_PRIORITY_DISPLAY);thread.start();
        handler=new Handler(thread.getLooper());
        reader=ImageReader.newInstance(m.w,m.h,PixelFormat.RGBA_8888,2);
        reader.setOnImageAvailableListener(r->{Image image=r.acquireLatestImage();if(image!=null)analyze(image,aw,ah);},handler);
        display=projection.createVirtualDisplay("AutoTrainerCapture",m.w,m.h,m.dpi,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,reader.getSurface(),null,handler);
        TrainerController.start(this);return START_NOT_STICKY;
    }

    private void analyze(Image image,int aw,int ah){
        try{
            Image.Plane p=image.getPlanes()[0];ByteBuffer b=p.getBuffer();
            int row=p.getRowStride(),pix=p.getPixelStride(),sw=image.getWidth(),sh=image.getHeight();
            int[] gray=new int[aw*ah];float usableH=.72f;
            for(int y=0;y<ah;y++){
                int iy=Math.min(sh-1,Math.max(0,(int)((y/(float)ah)*sh*usableH)));
                for(int x=0;x<aw;x++){
                    int ix=Math.min(sw-1,Math.max(0,(int)((x/(float)aw)*sw)));
                    int pos=iy*row+ix*pix;if(pos+2>=b.limit())continue;
                    int rr=b.get(pos)&255,gg=b.get(pos+1)&255,bb=b.get(pos+2)&255;
                    gray[y*aw+x]=(rr*30+gg*59+bb*11)/100;
                }
            }
            VisualObserver.Result result=observer.observe(gray);
            TrainerStateStore.record(System.currentTimeMillis(),result);
            TrainerController.onFrame(this,observer,result);
        }finally{image.close();}
    }
    private Notification notification(){return new Notification.Builder(this,"trainer").setContentTitle("Auto Trainer")
            .setContentText("Karmis-style visual loop активен").setSmallIcon(android.R.drawable.ic_menu_view).build();}
    private void createChannel(){if(Build.VERSION.SDK_INT>=26)((NotificationManager)getSystemService(NOTIFICATION_SERVICE))
            .createNotificationChannel(new NotificationChannel("trainer","Auto Trainer",NotificationManager.IMPORTANCE_LOW));}
    @Override public void onDestroy(){TrainerController.stop();if(display!=null)display.release();if(projection!=null)projection.stop();
        if(reader!=null)reader.close();if(thread!=null)thread.quitSafely();super.onDestroy();}
    @Override public IBinder onBind(Intent i){return null;}
    static class DisplayMetricsCompat{int w,h,dpi;DisplayMetricsCompat(Context c){android.util.DisplayMetrics m=c.getResources().getDisplayMetrics();
        w=m.widthPixels;h=m.heightPixels;dpi=m.densityDpi;}}
}
