package com.example.autotrainer;

import android.content.Context;
import android.content.SharedPreferences;

public final class TrainerController {
    private static final String PREF="trainer"; private static final long EPISODE_MS=6000,COOLDOWN_MS=900;
    private static long episodeStart,lastAction; private static boolean running; private static String goal="stand";
    private TrainerController(){}
    public static synchronized void start(Context c){running=true;episodeStart=System.currentTimeMillis();lastAction=0;goal=c.getSharedPreferences(PREF,0).getString("goal","stand");}
    public static synchronized void stop(){running=false;}
    public static synchronized void onFrame(Context c,VisualObserver o,VisualObserver.Result r){
        if(!running)return; long now=System.currentTimeMillis();
        if(r.state==VisualObserver.State.FALLING&&r.confidence>.72f&&now-lastAction>COOLDOWN_MS){act(c,false);episodeStart=now;o.reset();return;}
        if(now-episodeStart>=EPISODE_MS){
            boolean good="walk".equals(goal)?(!o.sawFall()&&o.stableRatio()<.78f):(!o.sawFall()&&o.stableRatio()>=.48f);
            act(c,good);episodeStart=now;o.reset();
        }
    }
    private static void act(Context c,boolean good){
        lastAction=System.currentTimeMillis();TrainerStateStore.verdict(good);
        SharedPreferences p=c.getSharedPreferences(PREF,0);
        p.edit().putInt("streak",TrainerStateStore.streak()).putInt("total",TrainerStateStore.total()).apply();
        // Default coordinates match Testung's bottom-menu reward row; normalized for screen size.
        TrainerAccessibilityService.tapNormalized(good?.125f:.375f,.735f,70);
    }
    public static void setGoal(Context c,String g){if(!"walk".equals(g))g="stand";c.getSharedPreferences(PREF,0).edit().putString("goal",g).apply();goal=g;}
}
