#define _DARWIN_C_SOURCE
#define _DEFAULT_SOURCE
#define _POSIX_C_SOURCE 200809L
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <dirent.h>
#include <sys/resource.h>
#include <sys/time.h>
#if defined(__APPLE__)
#include <mach/mach.h>
#include <sys/sysctl.h>
#include <libproc.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <net/if_dl.h>
#endif

/* -1 means unavailable; zero is a valid observation. Network excludes loopback. */
struct zigfs_host_metrics {
 double cpu_total, cpu_idle, cores, memory_total, memory_available;
 double virtual_bytes, peak_rss, threads, descriptors, descriptor_limit;
 double read_bytes, write_bytes, receive_bytes, transmit_bytes;
 double user_seconds, kernel_seconds, load1, load5, load15;
};
void zigfs_host_metrics_read(struct zigfs_host_metrics *m) {
 double *values=(double *)m;
 for (unsigned i=0;i<sizeof(*m)/sizeof(double);i++) values[i]=-1;
#if defined(__linux__) || defined(__APPLE__)
 m->cores=sysconf(_SC_NPROCESSORS_ONLN);
 struct rusage usage;
 if (getrusage(RUSAGE_SELF,&usage)==0) {
  m->user_seconds=usage.ru_utime.tv_sec+usage.ru_utime.tv_usec/1e6;
  m->kernel_seconds=usage.ru_stime.tv_sec+usage.ru_stime.tv_usec/1e6;
  m->peak_rss=usage.ru_maxrss;
#ifdef __linux__
  m->peak_rss*=1024;
#endif
 }
 struct rlimit limit;
 if (getrlimit(RLIMIT_NOFILE,&limit)==0 && limit.rlim_cur!=RLIM_INFINITY) m->descriptor_limit=limit.rlim_cur;
 double load[3];
 if(getloadavg(load,3)==3){m->load1=load[0];m->load5=load[1];m->load15=load[2];}
#endif
#ifdef __linux__
 FILE *f; char line[1024]; unsigned long long value;
 if((f=fopen("/proc/stat","r"))) {
  unsigned long long u,n,s,idle,wait,irq,soft,steal;
  if(fgets(line,sizeof(line),f) && sscanf(line,"cpu %llu %llu %llu %llu %llu %llu %llu %llu",&u,&n,&s,&idle,&wait,&irq,&soft,&steal)==8) {
   m->cpu_total=(double)u+n+s+idle+wait+irq+soft+steal; m->cpu_idle=(double)idle+wait;
  } fclose(f);
 }
 if((f=fopen("/proc/meminfo","r"))) {
  while(fgets(line,sizeof(line),f)) {
   if(sscanf(line,"MemTotal: %llu kB",&value)==1)m->memory_total=(double)value*1024;
   if(sscanf(line,"MemAvailable: %llu kB",&value)==1)m->memory_available=(double)value*1024;
  } fclose(f);
 }
 if((f=fopen("/proc/self/status","r"))) {
  while(fgets(line,sizeof(line),f)) {
   if(sscanf(line,"VmSize: %llu kB",&value)==1)m->virtual_bytes=(double)value*1024;
   if(sscanf(line,"Threads: %llu",&value)==1)m->threads=value;
  } fclose(f);
 }
 if((f=fopen("/proc/self/io","r"))) {
  while(fgets(line,sizeof(line),f)) {
   if(sscanf(line,"read_bytes: %llu",&value)==1)m->read_bytes=value;
   if(sscanf(line,"write_bytes: %llu",&value)==1)m->write_bytes=value;
  } fclose(f);
 }
 DIR *dir=opendir("/proc/self/fd");
 if(dir){ int count=0; struct dirent *entry; while((entry=readdir(dir))) if(entry->d_name[0]!='.')count++; closedir(dir); m->descriptors=count-1; }
 if((f=fopen("/proc/net/dev","r"))) {
  double rx=0,tx=0; int found=0;
  while(fgets(line,sizeof(line),f)) {
   char name[64]; unsigned long long r,t;
   if(sscanf(line," %63[^:]: %llu %*s %*s %*s %*s %*s %*s %*s %llu",name,&r,&t)==3 && strcmp(name,"lo")) {rx+=r;tx+=t;found=1;}
  } if(found){m->receive_bytes=rx;m->transmit_bytes=tx;} fclose(f);
 }
#elif defined(__APPLE__)
 mach_port_t host=mach_host_self();
 host_cpu_load_info_data_t cpu; mach_msg_type_number_t count=HOST_CPU_LOAD_INFO_COUNT;
 if(host_statistics(host,HOST_CPU_LOAD_INFO,(host_info_t)&cpu,&count)==KERN_SUCCESS){
  m->cpu_total=(double)cpu.cpu_ticks[CPU_STATE_USER]+cpu.cpu_ticks[CPU_STATE_SYSTEM]+cpu.cpu_ticks[CPU_STATE_IDLE]+cpu.cpu_ticks[CPU_STATE_NICE]; m->cpu_idle=cpu.cpu_ticks[CPU_STATE_IDLE];
 }
 uint64_t total; size_t size=sizeof(total);
 if(sysctlbyname("hw.memsize",&total,&size,NULL,0)==0)m->memory_total=total;
 vm_statistics64_data_t vm; count=HOST_VM_INFO64_COUNT; vm_size_t page;
 if(host_page_size(host,&page)==KERN_SUCCESS && host_statistics64(host,HOST_VM_INFO64,(host_info64_t)&vm,&count)==KERN_SUCCESS)m->memory_available=((double)vm.free_count+vm.inactive_count)*page;
 mach_port_deallocate(mach_task_self(),host);
 mach_task_basic_info_data_t info; count=MACH_TASK_BASIC_INFO_COUNT;
 if(task_info(mach_task_self(),MACH_TASK_BASIC_INFO,(task_info_t)&info,&count)==KERN_SUCCESS)m->virtual_bytes=info.virtual_size;
 thread_act_array_t threads; mach_msg_type_number_t thread_count;
 if(task_threads(mach_task_self(),&threads,&thread_count)==KERN_SUCCESS){m->threads=thread_count;for(unsigned i=0;i<thread_count;i++)mach_port_deallocate(mach_task_self(),threads[i]);vm_deallocate(mach_task_self(),(vm_address_t)threads,thread_count*sizeof(thread_t));}
 int bytes=proc_pidinfo(getpid(),PROC_PIDLISTFDS,0,NULL,0);
 if(bytes>0){void *fds=malloc((size_t)bytes);if(fds){int actual=proc_pidinfo(getpid(),PROC_PIDLISTFDS,0,fds,bytes);if(actual>0)m->descriptors=actual/sizeof(struct proc_fdinfo);free(fds);}}
 struct rusage_info_v2 ri;
 if(proc_pid_rusage(getpid(),RUSAGE_INFO_V2,(rusage_info_t *)&ri)==0){m->read_bytes=ri.ri_diskio_bytesread;m->write_bytes=ri.ri_diskio_byteswritten;}
 struct ifaddrs *addresses;
 if(getifaddrs(&addresses)==0){double rx=0,tx=0;int found=0;for(struct ifaddrs *p=addresses;p;p=p->ifa_next)if(p->ifa_addr && p->ifa_addr->sa_family==AF_LINK && !(p->ifa_flags&IFF_LOOPBACK) && p->ifa_data){struct if_data *d=p->ifa_data;rx+=d->ifi_ibytes;tx+=d->ifi_obytes;found=1;}if(found){m->receive_bytes=rx;m->transmit_bytes=tx;}freeifaddrs(addresses);}
#endif
}
