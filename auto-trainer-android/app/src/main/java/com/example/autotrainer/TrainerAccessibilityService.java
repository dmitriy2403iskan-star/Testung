package com.example.autotrainer;

import android.accessibilityservice.AccessibilityService;
import android.accessibilityservice.GestureDescription;
import android.graphics.Path;
import android.os.*;
import android.view.accessibility.AccessibilityEvent;

public class TrainerAccessibilityService extends AccessibilityService {
    private static volatile TrainerAccessibilityService instance;
    private final Handler main=new Handler(Looper.getMainLooper());
    public static boolean isReady(){return instance!=null;}
    public static void tapNormalized(float nx,float ny,long durationMs){TrainerAccessibilityService s=instance;if(s!=null)s.tap(nx,ny,durationMs);}
    @Override protected void onServiceConnected(){super.onServiceConnected();instance=this;}
    @Override public void onAccessibilityEvent(AccessibilityEvent event){}
    @Override public void onInterrupt(){}
    @Override public boolean onUnbind(android.content.Intent intent){instance=null;return super.onUnbind(intent);}
    @Override public void onDestroy(){instance=null;super.onDestroy();}
    private void tap(float nx,float ny,long duration){
        android.util.DisplayMetrics dm=getResources().getDisplayMetrics();
        final float x=Math.max(1,Math.min(dm.widthPixels-1,nx*dm.widthPixels)),y=Math.max(1,Math.min(dm.heightPixels-1,ny*dm.heightPixels));
        main.post(()->{Path p=new Path();p.moveTo(x,y);GestureDescription.Builder b=new GestureDescription.Builder();b.addStroke(new GestureDescription.StrokeDescription(p,0,Math.max(1,duration)));dispatchGesture(b.build(),null,null);});
    }
}
