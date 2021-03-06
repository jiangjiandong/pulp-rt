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

#include "rt/rt_data.h"
#if defined(ITC_VERSION)
#include "archi/itc/itc_v1.h"
#endif
#include "archi/eu/eu_v3.h"

#if defined(ARCHI_HAS_CLUSTER) && defined(ARCHI_HAS_FC)

    .section .cluster.text , "ax"

  .global __rt_task_master_entry
__rt_task_master_entry:
    la      t0, __rt_task_loop_entry
    li      t1, ARCHI_EU_DEMUX_ADDR
    sw      t0, EU_DISPATCH_DEMUX_OFFSET + EU_DISPATCH_FIFO_ACCESS(t1)
    sw      a0, EU_DISPATCH_DEMUX_OFFSET + EU_DISPATCH_FIFO_ACCESS(t1)



__rt_task_loop_entry:
    lw      s0, 16(a0)
    la      s1, __rt_task_first_cl
    li      s2, ARCHI_EU_DEMUX_ADDR
    li      s3, 1<<RT_CLUSTER_CALL_EVT
    csrr    s5, 0xF14
    and     s5, s5, 0x1f
    srli    s6, s5, 5
    la      s7, __rt_fc_cluster_data
    lw      s7, 0(s7)
    li      t2, RT_FC_CLUSTER_DATA_T_SIZEOF
    mul     t2, t2, s6
    add     s7, s7, t2
    addi    s7, s7, RT_FC_CLUSTER_DATA_T_EVENTS
#if defined(ITC_VERSION)
    li      s9, ARCHI_FC_ITC_ADDR + ITC_STATUS_SET_OFFSET
    li      s8, 1<<RT_FC_ENQUEUE_EVENT
#else
    li      s9, ARCHI_FC_GLOBAL_ADDR + ARCHI_FC_PERIPHERALS_OFFSET + ARCHI_FC_EU_OFFSET + EU_SW_EVENTS_AREA_BASE + EU_CORE_TRIGG_SW_EVENT + (RT_FC_ENQUEUE_EVENT << 2)
    li      s8, 1
#endif

    lw      t0, 4(a0)
    lw      sp, 0(a0)
    addi    t1, s5, 1
    mul     t0, t0, t1
    add     sp, sp, t0
    mv      s10, sp
    addi    s11, s2, RT_CLUSTER_CALL_EVT<<2
    mv      s5, ra

    j       __rt_task_loop



__rt_task_loop_wait:
    sw      s3, EU_CORE_MASK_OR(s2)
    p.elw   x0, EU_CORE_EVENT_WAIT_CLEAR(s2)
    sw      s3, EU_CORE_MASK_AND(s2)



__rt_task_loop:
    mv      t6, s0
    p.elw   t0, EU_MUTEX_DEMUX_OFFSET(s2)
    lw      a0, 0(s0)
    lw      t1, 0(s1)
    bnez    a0, __rt_task_fc
    bnez    t1, __rt_task_cl
    sw      x0, EU_MUTEX_DEMUX_OFFSET(s2)

    j __rt_task_loop_wait


__rt_task_cl:
    mv      t6, s1
    mv      a0, t1


__rt_task_fc:
    li      t5, -1
    beq     a0, t5, __rt_task_exit
    lb      a1, RT_TASK_T_NB_CORES(a0)
    bnez    a1, __rt_task_handle_from_fc_mc




//
// SINGLE CORE TASK
//

__rt_task_handle_from_fc:
    lw      t1, RT_TASK_T_NEXT(a0)
    lw      t2, RT_TASK_T_ENTRY(a0)
    sw      t1, 0(t6)

    sw      x0, EU_MUTEX_DEMUX_OFFSET(s2)

    lw      t3, RT_TASK_T_STACKS(a0)
    mv      s6, a0

    bnez    t3, __rt_task_handle_from_fc_stack

    jalr    ra, t2



    lw      t2, RT_TASK_T_EVENT(s6)

__rt_task_push_event_to_fc_retry:
    
    beqz    t2, __rt_task_cl_end

    p.elw   t0, EU_MUTEX_DEMUX_OFFSET(s2)

    // Now we have to push the termination event to FC side
    // First wait until the slot for posting events is free
    lw      t0, 0(s7)
    bne     t0, x0, __rt_task_push_event_to_fc_retry_unlock

    // Push it
    sw      t2, 0(s7)
    sw      x0, EU_MUTEX_DEMUX_OFFSET(s2)

    // And notify the FC side with a HW event in case it is sleeping
    sw      s8, 0(s9)

    j __rt_task_loop

__rt_task_cl_end:

    li      t2, 1
    sw      t2, RT_TASK_T_EVENT(s6)

    sw      x0, EU_SW_EVENTS_DEMUX_OFFSET + EU_CORE_TRIGG_SW_EVENT(s11)


    j __rt_task_loop



__rt_task_handle_from_fc_stack:
    mv      sp, t3

#ifdef __RT_USE_ASSERT
    // Update stack checking information
    la      t6, __rt_platform
    lh      t4, RT_TASK_T_STACK_SIZE(s6)
    lw      t6, 0(t6)
    li      t1, 3
    bne     t6, t1, __rt_task_handle_from_fc_stack_no_check
    sub     t6, sp, t4
    csrwi   0x7B0, 0
    csrw    0x7B1, t6
    csrw    0x7B2, sp
    csrwi   0x7B0, 1
#endif

__rt_task_handle_from_fc_stack_no_check:
    jalr    ra, t2

    mv      sp, s10

    lw      t2, RT_TASK_T_EVENT(s6)

    j __rt_task_push_event_to_fc_retry


__rt_task_push_event_to_fc_retry_unlock:
    sw      x0, EU_MUTEX_DEMUX_OFFSET(s2)
    j __rt_task_push_event_to_fc_retry




//
// MULTI CORE TASK
//

__rt_task_handle_from_fc_mc:

    lb      a1, RT_TASK_T_NB_CORES_TO_POP(a0)
    lw      t2, RT_TASK_T_ENTRY(a0)

    bnez    a1, __rt_task_fc_mc_no_dequeue
    lw      t1, RT_TASK_T_NEXT(a0)
    sw      t1, 0(t6)

__rt_task_fc_mc_no_dequeue:
    addi    t3, a1, -1
    sb      t3, RT_TASK_T_NB_CORES_TO_POP(a0)

    sw      x0, EU_MUTEX_DEMUX_OFFSET(s2)

    lw      t3, RT_TASK_T_STACKS(a0)
    mv      s6, a0
    bnez    t3, __rt_task_fc_mc_stack

    //add     sp, t3
    jalr    ra, t2

__rt_task_fc_mc_end:
    p.elw   t0, EU_MUTEX_DEMUX_OFFSET(s2)
    lb      t1, RT_TASK_T_NB_CORES_TO_END(s6)
    addi    t1, t1, -1
    sb      t1, RT_TASK_T_NB_CORES_TO_END(s6)
    lw      t2, RT_TASK_T_EVENT(s6)
    sw      x0, EU_MUTEX_DEMUX_OFFSET(s2)

    beqz    t1, __rt_task_push_event_to_fc_retry

    j __rt_task_loop


__rt_task_fc_mc_stack:
    lh      t4, RT_TASK_T_STACK_SIZE(s6)

    mul     t5, t4, a1
    add     sp, t3, t5

#ifdef __RT_USE_ASSERT
    // Update stack checking information
    la      t6, __rt_platform
    lw      t6, 0(t6)
    li      t1, 3
    bne     t6, t1, __rt_task_fc_mc_stack_no_check
    sub     t6, sp, t4
    csrwi   0x7B0, 0
    csrw    0x7B1, t6
    csrw    0x7B2, sp
    csrwi   0x7B0, 1
#endif

__rt_task_fc_mc_stack_no_check:
    jalr    ra, t2

    mv      sp, s10

    lw      t2, RT_TASK_T_EVENT(s6)

    j       __rt_task_fc_mc_end

#endif

__rt_task_exit:
    sw      x0, EU_MUTEX_DEMUX_OFFSET(s2)
    la      t1, _entry
    jr      t1
