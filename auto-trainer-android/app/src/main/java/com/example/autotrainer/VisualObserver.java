package com.example.autotrainer;

import java.util.ArrayDeque;

public final class VisualObserver {
    public enum State { UNKNOWN, STABLE, MOVING, FALLING }
    public static final class Result {
        public final State state; public final float motion, posture, confidence;
        Result(State s,float m,float p,float c){state=s;motion=m;posture=p;confidence=c;}
        public String toString(){return state+" m="+motion+" p="+posture+" c="+confidence;}
    }
    private final int w,h; private int[] prev,background;
    private final ArrayDeque<Result> history=new ArrayDeque<>();
    public VisualObserver(int w,int h){this.w=w;this.h=h;}
    public synchronized Result observe(int[] gray){
        if(gray==null||gray.length!=w*h)return new Result(State.UNKNOWN,0,0,0);
        if(prev==null){prev=gray.clone();background=gray.clone();return new Result(State.UNKNOWN,0,1,0);}
        float diff=0; int minX=w,minY=h,maxX=-1,maxY=-1;
        for(int y=4;y<h-4;y+=2)for(int x=2;x<w-2;x+=2){
            int i=y*w+x,d=Math.abs(gray[i]-prev[i]); diff+=d;
            if(Math.abs(gray[i]-background[i])>28){if(x<minX)minX=x;if(x>maxX)maxX=x;if(y<minY)minY=y;if(y>maxY)maxY=y;}
        }
        float motion=diff/(((w/2f)*(h/2f))*255f), posture=1f;
        if(maxX>=minX&&maxY>=minY)posture=(maxY-minY+1f)/Math.max(1f,maxX-minX+1f);
        if(motion<0.018f)for(int i=0;i<gray.length;i++)background[i]=(int)(background[i]*.98f+gray[i]*.02f);
        State s; float c;
        if(posture<.72f&&motion>.025f){s=State.FALLING;c=Math.min(1f,.55f+motion*8f);}
        else if(motion<.012f){s=State.STABLE;c=Math.min(1f,.65f+(.012f-motion)*20f);}
        else{s=State.MOVING;c=Math.min(1f,.45f+motion*4f);}
        prev=gray.clone(); Result r=new Result(s,motion,posture,c); history.addLast(r);
        while(history.size()>48)history.removeFirst(); return r;
    }
    public synchronized float stableRatio(){if(history.isEmpty())return 0;int n=0;for(Result r:history)if(r.state==State.STABLE)n++;return n/(float)history.size();}
    public synchronized boolean sawFall(){for(Result r:history)if(r.state==State.FALLING)return true;return false;}
    public synchronized void reset(){prev=null;background=null;history.clear();}
}
