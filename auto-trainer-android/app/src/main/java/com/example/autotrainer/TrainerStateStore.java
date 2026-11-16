package com.example.autotrainer;

import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.List;

public final class TrainerStateStore {
    public static final class Observation {
        public final long time; public final float motion,posture,confidence; public final String state;
        Observation(long t,float m,float p,String s,float c){time=t;motion=m;posture=p;state=s;confidence=c;}
    }
    private static final ArrayDeque<Observation> frames=new ArrayDeque<>();
    private static volatile String state="UNKNOWN"; private static volatile float confidence=0;
    private static volatile int streak=0,total=0;
    public static synchronized void record(long t,VisualObserver.Result r){
        state=r.state.name();confidence=r.confidence;frames.addLast(new Observation(t,r.motion,r.posture,state,r.confidence));
        while(frames.size()>180)frames.removeFirst();
    }
    public static synchronized List<Observation> snapshot(){return new ArrayList<>(frames);}
    public static String state(){return state;} public static float confidence(){return confidence;}
    public static int streak(){return streak;} public static int total(){return total;}
    public static synchronized void verdict(boolean good){total++;streak=good?streak+1:0;}
}
