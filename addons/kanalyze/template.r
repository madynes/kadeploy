library(ggplot2)

args=commandArgs(TRUE)

files=args

data=data.frame()

for (file in files)
{
	if(length(data)==0)
	{
		data<-read.csv(file,head=TRUE,sep=",")
	}
	else
	{
		data<-rbind(data,read.csv(file,head=TRUE,sep=","))
	}
}

numl=length(data[,1])
numc=length(data[1,])

zeros=rep(0,numl)
times_df=cbind(zeros,data$time1,data$time2,data$time3)
cumtimes_tmp=apply(times_df,1,cumsum)
cumtimes=as.vector(cumtimes_tmp)

maxis=apply(cumtimes_tmp,1,max)
minis=apply(cumtimes_tmp,1,min)
means=apply(cumtimes_tmp,1,mean)
cumtimes_stats=as.vector(cbind(maxis,minis,means))

run_ids=as.vector(apply(data["id"],1,function(x) rep(x,4)))
run_ids_stats=as.vector(sapply(c("Maximum","Minimum","Mean"),function(x) rep(x,4)))

times=as.vector(t(cbind(data["time1"],data["time2"],data["time3"])))
times1=as.vector(t(data["time1"]))
times2=as.vector(t(data["time2"]))
times3=as.vector(t(data["time3"]))

kadeploy_version=as.vector(t(data["kadeploy"]))
names1=as.vector(t(data["step1"]))
names2=as.vector(t(data["step2"]))
names3=as.vector(t(data["step3"]))

experiments=as.vector(t(data["expname"]))
success=as.vector(t(data["n_success"]))
fail=as.vector(t(data["n_fail"]))
run_ids_success=as.vector(t(data["id"]))
iters=as.vector(t(data["iter"]))

output=c()

success_percent=success*100/(success+fail)
success_mean_percent=mean(success_percent)
time1_mean=mean(times1)
time2_mean=mean(times2)
time3_mean=mean(times3)

output=c(output,paste("Success Rate \\dotfill",round(success_mean_percent,2),"\\% \\\\"))
output=c(output,paste("Number of nodes\\dotfill",max(success+fail),"\\\\"))
output=c(output,paste("Step1 duration mean \\dotfill",round(time1_mean,2),"s \\\\"))
output=c(output,paste("Step2 duration mean \\dotfill",round(time2_mean,2),"s \\\\"))
output=c(output,paste("Step3 duration mean \\dotfill",round(time3_mean,2),"s \\\\"))

for(level in levels(data$kadeploy))
{
	dataset=subset(data,kadeploy==level)
	output=c(output,paste("Step1 duration mean for Kadeploy",level,"\\dotfill",round(mean(as.vector(t(dataset["time1"]))),2),"s \\\\"))
	output=c(output,paste("Step2 duration mean for Kadeploy",level,"\\dotfill",round(mean(as.vector(t(dataset["time2"]))),2),"s \\\\"))
	output=c(output,paste("Step3 duration mean for Kadeploy",level,"\\dotfill",round(mean(as.vector(t(dataset["time3"]))),2),"s \\\\"))
}

times1_by_macro=subset(data,select=c("step1","time1"))
times2_by_macro=subset(data,select=c("step2","time2"))
times3_by_macro=subset(data,select=c("step3","time3"))
for(level in levels(data$step1))
{
	time1_by_macro_mean=mean(t(subset(times1_by_macro,step1==level)["time1"]))
	output=c(output,paste(level,"duration mean \\dotfill",round(time1_by_macro_mean,2),"s \\\\"))
}
for(level in levels(data$step2))
{
	time2_by_macro_mean=mean(t(subset(times2_by_macro,step2==level)["time2"]))
	output=c(output,paste(level,"duration mean \\dotfill",round(time2_by_macro_mean,2),"s \\\\"))
}
for(level in levels(data$step3))
{
	time3_by_macro_mean=mean(t(subset(times3_by_macro,step3==level)["time3"]))
	output=c(output,paste(level,"duration mean \\dotfill",round(time3_by_macro_mean,2),"s \\\\"))
}

dir.create("pictures")

steps=c("0","step1","step2","step3")
fr=data.frame(cumtimes_stats,steps,run_ids_stats)

graph<-ggplot(fr,aes(x=steps,y=cumtimes_stats,color=run_ids_stats,group=run_ids_stats))+geom_point()+geom_line()#+theme(legend.position="bottom")
graph<-graph+ylab("Time (s)")+xlab("Steps")+ggtitle("Evolution of steps on the time")+scale_fill_discrete(name="Runs")
ggsave(file=paste("pictures/steps-line.jpeg",sep=""),dpi=300)

steps=c("step1","step2","step3")
fr=data.frame(times,steps)

graph<-ggplot(fr,aes(x=steps,y=times,fill=steps,group=steps))+geom_boxplot(alpha=.5)+geom_line()+theme(legend.position="bottom")
graph<-graph+ylab("Time (s)")+xlab("Steps")+ggtitle("Times of steps")+scale_fill_discrete(name="Steps")
ggsave(file=paste("pictures/steps-boxplot.jpeg",sep=""),dpi=300)

groups=paste(kadeploy_version,names1)
fr=data.frame(times1,groups,kadeploy_version)

graph<-ggplot(fr,aes(x=groups,y=times1,fill=kadeploy_version,group=groups))+geom_boxplot(alpha=.5)+geom_line()
graph=graph+scale_fill_discrete(name="Kadeploy Versions")
graph<-graph+ylab("Time (s)")+xlab("Versions")+ggtitle(paste("Times of step 1 for different versions of Kadeploy"))
graph<-graph+theme(axis.text.x = element_text(angle = 90))
ggsave(file=paste("pictures/boxplot1-per-kadeploy.jpeg",sep=""),dpi=300)

groups=paste(kadeploy_version,names2)
fr=data.frame(times2,groups,kadeploy_version)

graph<-ggplot(fr,aes(x=groups,y=times2,fill=kadeploy_version,group=groups))+geom_boxplot(alpha=.5)+geom_line()
graph=graph+scale_fill_discrete(name="Kadeploy Versions")
graph<-graph+ylab("Time (s)")+xlab("Versions")+ggtitle(paste("Times of step 2 for different versions of Kadeploy"))
graph<-graph+theme(axis.text.x = element_text(angle = 90))
ggsave(file=paste("pictures/boxplot2-per-kadeploy.jpeg",sep=""),dpi=300)

groups=paste(kadeploy_version,names3)
fr=data.frame(times3,groups,kadeploy_version)

graph<-ggplot(fr,aes(x=groups,y=times3,fill=kadeploy_version,group=groups))+geom_boxplot(alpha=.5)+geom_line()
graph=graph+scale_fill_discrete(name="Kadeploy Versions")
graph<-graph+ylab("Time (s)")+xlab("Versions")+ggtitle(paste("Times of step 3 for different versions of Kadeploy"))
graph<-graph+theme(axis.text.x = element_text(angle = 90))
ggsave(file=paste("pictures/boxplot3-per-kadeploy.jpeg",sep=""),dpi=300)

groups=paste(experiments,sprintf("%03i",iters))
fr=data.frame(groups,success_percent,experiments)
fr=aggregate(success_percent ~ groups + experiments ,fr,mean)

graph<-ggplot(fr,aes(x=groups,y=success_percent,fill=experiments))+geom_bar(stat="identity",alpha=.5)
graph=graph+scale_fill_discrete(name="Experiments")
graph<-graph+ylab("Success Rate (%)")+xlab("Runs")+ggtitle(paste("Success rate of different test runs"))
graph<-graph+theme(axis.text.x = element_text(angle = 90))
ggsave(file=paste("pictures/success.jpeg",sep=""),dpi=300)

#---MICROSTEPS---
microtimes1_cols=c()
microtimes2_cols=c()
microtimes3_cols=c()
microids1=c()
microids2=c()
microids3=c()

for(col in colnames(data))
{
	if(substr(col,1,6)=="time1_")
	{
		microtimes1_cols<-c(microtimes1_cols,col)
	}
	if(substr(col,1,6)=="time2_")
	{
		microtimes2_cols<-c(microtimes2_cols,col)
	}
	if(substr(col,1,6)=="time3_")
	{
		microtimes3_cols<-c(microtimes3_cols,col)
	}
	if(substr(col,1,6)=="step1_")
	{
		microids1<-c(microids1,col)
	}
	if(substr(col,1,6)=="step2_")
	{
		microids2<-c(microids2,col)
	}
	if(substr(col,1,6)=="step3_")
	{
		microids3<-c(microids3,col)
	}
}
microtimes1_df<-subset(data,select=microtimes1_cols)
microtimes2_df<-subset(data,select=microtimes2_cols)
microtimes3_df<-subset(data,select=microtimes3_cols)

microtimes_df=cbind(microtimes1_df,microtimes2_df,microtimes3_df)
microids=c(microids1,microids2,microids3)
cumicrotimes=as.vector(apply(microtimes_df,1,cumsum))
microrun_ids=as.vector(apply(data["id"],1,function(x) rep(x,length(microtimes_df))))

microtimes1=as.vector(t(microtimes1_df))
microtimes2=as.vector(t(microtimes2_df))
microtimes3=as.vector(t(microtimes3_df))

micronames_out=c()
micronames=unique(subset(data,select=microids))
prevstep = gsub(":.*","",micronames[,1])
for(i in 1:length(micronames))
{
  curstep = gsub(":.*","",micronames[,i])
  if (curstep!=prevstep)
  {
    micronames_out=c(micronames_out,"\\hline")
  }
  micronames_out=c(micronames_out,paste(colnames(micronames)[i]," & ",gsub("step.*:","",micronames[,i]),"\\\\"))
  prevstep = curstep
}

con <- file("micronames.tex", open = "w")
writeLines(gsub("\\_","\\\\_",micronames_out), con = con)
close(con)


fr=data.frame(cumicrotimes,microids,microrun_ids)
graph<-ggplot(fr,aes(x=microids,y=cumicrotimes,color=microrun_ids,group=microrun_ids))+geom_point()+geom_line()
graph<-graph+xlab("Microsteps")+ylab("Time (s)")+ggtitle("Evolution of microsteps on the time")+scale_fill_discrete(name="Runs")
graph<-graph+theme(axis.text.x = element_text(angle = 90))
ggsave(file=paste("pictures/microsteps-line.jpeg",sep=""),dpi=300)

fr=data.frame(microtimes1,microids1)
graph<-ggplot(fr,aes(x=microids1,y=microtimes1,fill=microids1,group=microids1))+geom_boxplot(alpha=.5)+geom_line()
graph<-graph+ylab("Time (s)")+xlab("Microsteps")+ggtitle(levels(data$step1))
graph<-graph+scale_fill_discrete(name="Microsteps")
ggsave(file=paste("pictures/microsteps1-boxplot.jpeg",sep=""),dpi=300)

fr=data.frame(microtimes2,microids2)
graph<-ggplot(fr,aes(x=microids2,y=microtimes2,fill=microids2,group=microids2))+geom_boxplot(alpha=.5)+geom_line()
graph<-graph+ylab("Time (s)")+xlab("Microsteps")+ggtitle(levels(data$step2))
graph<-graph+scale_fill_discrete(name="Microsteps")
ggsave(file=paste("pictures/microsteps2-boxplot.jpeg",sep=""),dpi=300)

fr=data.frame(microtimes3,microids3)
graph<-ggplot(fr,aes(x=microids3,y=microtimes3,fill=microids3,group=microids3))+geom_boxplot(alpha=.5)+geom_line()
graph<-graph+ylab("Time (s)")+xlab("Microsteps")+ggtitle(levels(data$step3))
graph<-graph+scale_fill_discrete(name="Microsteps")
ggsave(file=paste("pictures/microsteps3-boxplot.jpeg",sep=""),dpi=300)
#---MICROSTEPS---

con <- file("data.tex", open = "w")
writeLines(gsub("\\_","\\\\_",output), con = con)
close(con)
