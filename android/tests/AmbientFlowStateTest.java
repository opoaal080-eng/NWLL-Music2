package fun.nightwell.music;
public final class AmbientFlowStateTest {
    static void check(boolean condition,String reason){if(!condition)throw new AssertionError(reason);}
    static final boolean[] ALL={true,true,true,true};
    public static void main(String[] args){
        AmbientFlowState state=new AmbientFlowState();
        for(int i=0;i<60;i++)state.update(new double[]{0,0,0,0},ALL,1,1,1.0/30);
        for(double level:state.levels)check(level==0,"Silence must not create audio energy");
        for(int i=0;i<30;i++)state.update(new double[]{0,.2,0,0},ALL,1,1,1.0/30);
        check(state.levels[1]>.5,"Bass must visibly excite its stream");
        check(state.levels[0]==0&&state.levels[2]==0&&state.levels[3]==0,"Bands must stay independent");
        double peak=state.levels[1];
        state.update(new double[4],ALL,1,1,1.0/30);
        check(state.levels[1]>0&&state.levels[1]<peak,"Release must be smooth");
        for(int i=0;i<180;i++)state.update(new double[4],ALL,1,1,1.0/30);
        check(state.levels[1]<.001,"Silence must fully fade the wave");
        state.update(new double[]{1,1,1,1},new boolean[4],1,1,.1);
        for(double level:state.levels)check(level==0,"Disabled bands must be dark");
        state.update(new double[]{1,1,1,1},ALL,0,1,.1);
        for(double level:state.levels)check(level==0,"Zero intensity must be dark");
        state.update(new double[]{Double.NaN,Double.POSITIVE_INFINITY,-1,99},ALL,Double.NaN,Double.NaN,1000);
        for(double level:state.levels)check(Double.isFinite(level)&&level>=0&&level<=1,"Malformed samples must stay bounded");
        double before=state.time;state.reset();
        for(double level:state.levels)check(level==0,"Pause resets audio envelopes");
        check(state.time==before,"Pause must preserve the wave position");
        AmbientFlowState slow=new AmbientFlowState(),fast=new AmbientFlowState();
        for(int i=0;i<60;i++)slow.update(new double[]{.1,.2,.3,.4},ALL,1,1,1.0/30);
        for(int i=0;i<120;i++)fast.update(new double[]{.1,.2,.3,.4},ALL,1,1,1.0/60);
        for(int i=0;i<4;i++)check(Math.abs(slow.levels[i]-fast.levels[i])<.02,"Response must not depend on display refresh rate");
        System.out.println("Ambient Flow: silence, bands, release, switches, gain, malformed samples, pause and frame rates passed");
    }
}
