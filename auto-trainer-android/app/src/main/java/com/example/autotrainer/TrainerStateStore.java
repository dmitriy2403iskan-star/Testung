package com.example.autotrainer;
import android.content.*;
import java.util.*;
public final class TrainerStateStore {
    private static final ArrayList<String> frames=new ArrayList<>();
    private TrainerStateStore(){}
    public static synchronized void recordFrame(long t,float motion){ frames.add(t+","+motion); if(frames.size()>120)frames.remove(0); }
    public static synchronized List<String> snapshot(){ return new ArrayList<>(frames); }
}