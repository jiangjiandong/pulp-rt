/*
 * Copyright (C) 2018 ETH Zurich and University of Bologna
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/* 
 * Authors: Germain Haugou, ETH (germain.haugou@iis.ee.ethz.ch)
 */

#include "rt/rt_api.h"
#include "stdio.h"

#if defined(ARCHI_HAS_CLUSTER)

rt_fc_cluster_data_t *__rt_fc_cluster_data;
RT_L1_TINY_DATA __rt_cluster_call_t __rt_cluster_call[2];
RT_L1_TINY_DATA rt_event_sched_t *__rt_cluster_sched_current;

void __rt_enqueue_event();
void __rt_remote_enqueue_event();

extern char _l1_preload_start_inL2[];
extern char _l1_preload_start[];
extern char _l1_preload_size[];

extern void _start();

static void __rt_init_cluster_data(int cid)
{

#if defined(ARCHI_HAS_FC) && ARCHI_HAS_FC == 1
  // In case the chip does not support L1 preloading, the initial L1 data are in L2, we need to copy them to L1
  int *l1_preload_start = (int *)rt_cluster_tiny_addr(cid, (void *)&_l1_preload_start);
  int *l1_preload_start_inL2 = (int *)&_l1_preload_start_inL2;
  int l1_preload_size = (int)&_l1_preload_size;

  rt_trace(RT_TRACE_INIT, "L1 preloading data copy from L2 to L1 (L2 start: 0x%x, L2 end: 0x%x, L1 start: 0x%x)\n", (int)l1_preload_start_inL2, (int)l1_preload_start_inL2 + l1_preload_size, (int)l1_preload_start);
  for (; l1_preload_size > 0; l1_preload_size-=4, l1_preload_start++, l1_preload_start_inL2++) {
    *l1_preload_start = *l1_preload_start_inL2;
  }

#endif

  int nb_cluster = rt_nb_cluster();

  memset(rt_cluster_tiny_addr(cid, __rt_cluster_call), 0, sizeof(__rt_cluster_call));

  __rt_fc_cluster_data[cid].call_stacks = NULL;
  __rt_fc_cluster_data[cid].trig_addr = eu_evt_trig_cluster_addr(cid, RT_CLUSTER_CALL_EVT);
}

static inline __attribute__((always_inline)) void __rt_cluster_mount(int cid, int flags, rt_event_t *event)
{
  rt_trace(RT_TRACE_CONF, "Mounting cluster (cluster: %d)\n", cid);

  if (rt_is_fc() || (cid && !rt_has_fc()))
  {
    // Power-up the cluster
    // For now the PMU is only supporting one cluster
    if (cid == 0) __rt_pmu_cluster_power_up();

#ifdef FLL_VERSION
    if (rt_platform() != ARCHI_PLATFORM_FPGA)
    {
      // Setup FLL
      __rt_fll_init(1);
    }
#endif

    /* Activate cluster top level clock gating */
#ifdef ARCHI_HAS_CLUSTER_CLK_GATE
    IP_WRITE(ARCHI_CLUSTER_PERIPHERALS_GLOBAL_ADDR(cid), ARCHI_CLUSTER_CTRL_CLUSTER_CLK_GATE, 1);
#endif

    // Initialize cluster global variables
    __rt_init_cluster_data(cid);

    // Initialize cluster L1 memory allocator
    __rt_alloc_init_l1(cid);

    // Initialize FC data for this cluster
    __rt_fc_cluster_data[cid].call_head = 0;

    // Activate icache
    hal_icache_cluster_enable(cid);

#if defined(APB_SOC_VERSION) && APB_SOC_VERSION >= 2

    // Fetch all cores, they will directly jump to the PE loop waiting from orders through the dispatcher
    for (int i=0; i<rt_nb_pe(); i++) {
      plp_ctrl_core_bootaddr_set_remote(cid, i, ((int)_start) & 0xffffff00);
    }
    eoc_fetch_enable_remote(cid, -1);

    // For now the whole sequence is blocking so we just handle the event here.
    // The power-up sequence could be done asynchronously and would then use the event
    if (event) rt_event_push(event);

#endif

  }
  else
  {
    // Initialize cluster global variables
    __rt_init_cluster_data(cid);

    // Activate icache
    hal_icache_cluster_enable(cid);

    // Only initialize it if it is not our own allocator as in this case
    // it has already been initialized during start-up

#if defined(APB_SOC_VERSION) && APB_SOC_VERSION >= 2

    eoc_fetch_enable_remote(cid, -1);    

#endif

  }
}

static inline __attribute__((always_inline)) void __rt_cluster_unmount(int cid, int flags, rt_event_t *event)
{
  rt_trace(RT_TRACE_CONF, "Unmounting cluster (cluster: %d)\n", cid);

#ifdef FLL_VERSION
    if (rt_platform() != ARCHI_PLATFORM_FPGA)
    {
      __rt_fll_deinit(1);
    }
#endif

  // Power-up the cluster
  // For now the PMU is only supporting one cluster
  if (cid == 0) __rt_pmu_cluster_power_down();

  // For now the whole sequence is blocking so we just handle the event here.
  // The power-down sequence could be done asynchronously and would then use the event
  if (event) rt_event_push(event);
}



void rt_cluster_mount(int mount, int cid, int flags, rt_event_t *event)
{
  int irq = hal_irq_disable();

  rt_fc_cluster_data_t *cluster = &__rt_fc_cluster_data[cid];

  if (mount) cluster->mount_count++;
  else cluster->mount_count--;

  if (cluster->mount_count == 0) __rt_cluster_unmount(cid, flags, event);
  else if (cluster->mount_count == 1) __rt_cluster_mount(cid, flags, event);

  hal_irq_restore(irq);
}



int rt_cluster_call(rt_cluster_call_t *_call, int cid, void (*entry)(void *arg), void *arg, void *stacks, int master_stack_size, int slave_stack_size, int nb_pe, rt_event_t *event)
{
  int retval = 0;
  int irq = hal_irq_disable();

  __rt_cluster_call_t *call;
  rt_fc_cluster_data_t *cluster = &__rt_fc_cluster_data[cid];

  // Loop until we get a free cluster call structure
  // It is important to reload the index after a wake-up, as another thread could have pushed something
  do {
    // Get the current structure
    int index = cluster->call_head;
    call = rt_cluster_tiny_addr(cid, &__rt_cluster_call[index]);

    // Go to sleep if there is noone available
    if ((*(volatile int *)&call->nb_pe) == 0) break;

    __rt_thread_sleep();
  } while(1);

  cluster->call_head ^= 1;

  if (cluster->call_stacks != NULL) {
    rt_free(RT_ALLOC_CL_DATA+cid, cluster->call_stacks, cluster->call_stacks_size);
    cluster->call_stacks = NULL;
  }

  // If no stack is specified, choose a default one.
  if (master_stack_size == 0) master_stack_size = rt_cl_master_stack_size_get();
  if (slave_stack_size == 0) slave_stack_size = rt_cl_slave_stack_size_get();
  if (stacks == NULL)
  {
    cluster->call_stacks_size = master_stack_size + slave_stack_size*nb_pe;
    stacks = rt_alloc(RT_ALLOC_CL_DATA+cid, cluster->call_stacks_size);
    if (stacks == NULL) {
      retval = -1;
      goto end;
    }
    cluster->call_stacks = stacks;
  }

  rt_event_t *call_event = __rt_wait_event_prepare(event);

  // Fill-in the call request
  call->entry = entry;
  call->arg = arg;
  // Compute directly the right stack pointer for master and this will also ease setting stack for slaves
  call->stacks = (void *)((int)stacks + master_stack_size);
  call->master_stack_size = master_stack_size;
  call->slave_stack_size = slave_stack_size;
  call->event = call_event;
  call->sched = call_event->sched;

  // nb_pe must be last written as this is the one triggering the execution on cluster side
  rt_compiler_barrier();
  call->nb_pe = nb_pe;

  // And trigger an event on cluster side in case it is sleeping
  eu_evt_trig(eu_evt_trig_cluster_addr(cid, RT_CLUSTER_CALL_EVT), 1);

  if (rt_is_fc()) __rt_wait_event_check(event, call_event);

end:
  hal_irq_restore(irq);
  return retval;
}

static RT_FC_BOOT_CODE int __rt_cluster_init(void *arg)
{
  int nb_cluster = rt_nb_cluster();
  int data_size = sizeof(rt_fc_cluster_data_t)*nb_cluster;

  __rt_fc_cluster_data = rt_alloc(RT_ALLOC_FC_DATA, data_size);
  if (__rt_fc_cluster_data == NULL) {
    rt_fatal("Unable to allocate cluster control structure\n");
    return -1;
  }

  memset(__rt_fc_cluster_data, 0, data_size);

  rt_irq_set_handler(RT_FC_ENQUEUE_EVENT, __rt_remote_enqueue_event);
  rt_irq_mask_set(1<<RT_FC_ENQUEUE_EVENT);

  return 0;
}


#if defined(ARCHI_HAS_FC)

void __rt_cluster_push_fc_event(rt_event_t *event)
{
  eu_mutex_lock(eu_mutex_addr(0));

  rt_fc_cluster_data_t *data = &__rt_fc_cluster_data[rt_cluster_id()];

  // First wait until the slot to post events is free
  while(data->events != NULL)
  {
    eu_evt_maskWaitAndClr(1<<RT_CLUSTER_CALL_EVT);
  }

  // Push the event and notify the FC with a HW evet in case it
  // is sleeping
  data->events = event;
#ifdef ITC_VERSION
  hal_itc_status_set(1<<RT_FC_ENQUEUE_EVENT);
#else
  eu_evt_trig(eu_evt_trig_fc_addr(RT_FC_ENQUEUE_EVENT), 0);
#endif

  eu_mutex_unlock(eu_mutex_addr(0));
}

#endif


RT_FC_BOOT_CODE void __attribute__((constructor)) __rt_cluster_new()
{
  int err = 0;

  err |= __rt_cbsys_add(RT_CBSYS_START, __rt_cluster_init, NULL);

  if (err) rt_fatal("Unable to initialize time driver\n");
}

#else

void rt_cluster_mount(int mount, int cid, int flags, rt_event_t *event)
{
}

int rt_cluster_call(rt_cluster_call_t *_call, int cid, void (*entry)(void *arg), void *arg, void *stacks, int master_stack_size, int slave_stack_size, int nb_pe, rt_event_t *event)
{
  return 0;
}

#endif


#if defined(ARCHI_HAS_CLUSTER)

void rt_cluster_notif_init(rt_notif_t *notif, int cluster_id)
{
  notif->trig_addr = eu_evt_trig_cluster_addr(cluster_id, RT_CLUSTER_TRIGGER_EVT);
  notif->event_id = 1 << RT_CLUSTER_TRIGGER_EVT;
}
void rt_cluster_notif_deinit(rt_notif_t *notif)
{
}

#endif

#if !defined(RISCV_VERSION) || RISCV_VERSION < 4

void __rt_remote_enqueue_event()
{

}

#endif


#if defined(ARCHI_HAS_CLUSTER)

extern int main();

static void cluster_pe_start(void *arg)
{
  hal_irq_enable();
  main();
}

static void __rt_cluster_start(void *arg)
{
#if defined(EU_VERSION) && EU_VERSION >= 3
  eu_evt_maskSet((1<<PULP_DISPATCH_EVENT) | (1<<PULP_HW_BAR_EVENT) | (1<<PULP_MUTEX_EVENT));
  rt_team_fork(rt_nb_pe(), cluster_pe_start, NULL);
#endif
}

int rt_cluster_fetch_all(int cid)
{
  rt_cluster_mount(1, cid, 0, NULL);
  return rt_cluster_call(NULL, cid, __rt_cluster_start, NULL, NULL, 0, 0, rt_nb_pe(), NULL);
}

#else

int rt_cluster_fetch_all(int cid)
{
  return 0;
}

#endif
