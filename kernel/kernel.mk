
# In case the architecture does not have any fabric controller, the FC code will run
# on pe0 of cluster0
fc_archi = $(fc/archi)
ifeq '$(fc/archi)' ''
fc_archi = $(pe/archi)
endif


PULP_LIB_FC_SRCS_rt     += kernel/init.c \
   kernel/dev.c kernel/irq.c kernel/debug.c \
  kernel/utils.c kernel/error.c kernel/bridge.c kernel/conf.c
PULP_LIB_FC_ASM_SRCS_rt += kernel/$(fc_archi)/thread.S

ifneq '$(cluster/version)' ''
PULP_LIB_FC_SRCS_rt     += kernel/task.c
PULP_LIB_FC_ASM_SRCS_rt += kernel/$(fc_archi)/task.S
endif


ifeq '$(pulp_chip)' 'oprecompkw'
PULP_LIB_FC_ASM_SRCS_rt += kernel/oprecompkw/rt/crt0.S
else
PULP_LIB_FC_ASM_SRCS_rt += kernel/$(fc_archi)/rt/crt0.S
endif

ifeq '$(CONFIG_SCHED_ENABLED)' '1'
PULP_LIB_FC_SRCS_rt     += kernel/thread.c kernel/events.c
endif



ifeq '$(CONFIG_ALLOC_ENABLED)' '1'
PULP_LIB_FC_SRCS_rt     += kernel/alloc.c kernel/alloc_extern.c
endif



ifeq '$(CONFIG_TIME_ENABLED)' '1'
PULP_LIB_FC_SRCS_rt     += kernel/time.c kernel/time_irq.c
endif



ifneq '$(fc_archi)' 'or1k'
PULP_LIB_FC_ASM_SRCS_rt += kernel/$(fc_archi)/sched.S kernel/$(fc_archi)/vectors.S
endif

ifneq '$(udma/version)' ''
PULP_LIB_FC_SRCS_rt     += kernel/periph-v$(udma/archi).c
PULP_LIB_FC_ASM_SRCS_rt += kernel/$(fc_archi)/udma-v$(udma/archi).S kernel/$(fc_archi)/udma_spim-v$(udma/spim/version).S
endif

ifneq '$(soc/fll/version)' ''
ifeq '$(pulp_chip_family)' 'gap'
PULP_LIB_FC_SRCS_rt     += kernel/gap/freq.c kernel/gap/pm.c
else
ifeq '$(pulp_chip)' 'arnold'
PULP_LIB_FC_SRCS_rt     += kernel/fll-v$(fll/version).c
PULP_LIB_FC_SRCS_rt     += kernel/freq-one-per-domain.c
else
ifeq '$(pulp_chip)' 'pulp'
PULP_LIB_FC_SRCS_rt     += kernel/fll-v$(fll/version).c
PULP_LIB_FC_SRCS_rt     += kernel/freq-one-per-domain.c
else
ifeq '$(pulp_chip_family)' 'pulpissimo'
PULP_LIB_FC_SRCS_rt     += kernel/fll-v$(fll/version).c
PULP_LIB_FC_SRCS_rt     += kernel/freq-one-per-domain.c
else
ifeq '$(pulp_chip_family)' 'pulpissimo_v2'
PULP_LIB_FC_SRCS_rt     += kernel/fll-v$(fll/version).c
PULP_LIB_FC_SRCS_rt     += kernel/freq-one-per-domain.c
else
ifeq '$(pulp_chip_family)' 'vega'
PULP_LIB_FC_SRCS_rt     += kernel/fll-v$(fll/version).c
PULP_LIB_FC_SRCS_rt     += kernel/freq-one-per-domain.c
else
PULP_LIB_FC_SRCS_rt     += kernel/fll-v$(fll/version).c
PULP_LIB_FC_SRCS_rt     += kernel/freq-v$(fll/version).c
endif
endif
endif
endif
endif
endif
endif

ifneq '$(soc_eu/version)' ''
ifneq '$(fc_itc)' ''
PULP_LIB_FC_ASM_SRCS_rt += kernel/$(fc_archi)/soc_event_itc-v$(soc_eu/version).S
else
PULP_LIB_FC_ASM_SRCS_rt += kernel/$(fc_archi)/soc_event_eu.S
endif
endif

PULP_LIB_CL_ASM_SRCS_rt += kernel/$(fc_archi)/pe-eu-v$(event_unit/version).S

ifeq '$(event_unit/version)' '1'
PULP_LIB_FC_SRCS_rt += kernel/riscv/pe-eu-v1-entry.c
endif

ifeq '$(pulp_chip_family)' 'wolfe'
PULP_LIB_FC_SRCS_rt += kernel/wolfe/maestro.c
endif

ifeq '$(pulp_chip_family)' 'devchip'
PULP_LIB_FC_SRCS_rt += kernel/wolfe/maestro.c
endif

ifeq '$(pulp_chip_family)' 'vega'
PULP_LIB_FC_SRCS_rt += kernel/vega/maestro.c
endif

ifeq '$(pulp_chip_family)' 'gap'
PULP_LIB_FC_SRCS_rt += kernel/gap/maestro.c kernel/gap/pmu_driver.c
endif


ifeq '$(pulp_chip_family)' 'vivosoc3'
PULP_LIB_FC_SRCS_rt     += kernel/vivosoc3/fll.c 
PULP_LIB_FC_SRCS_rt     += kernel/vivosoc3/freq.c
endif

ifeq '$(pulp_chip_family)' 'vivosoc3_1'
PULP_LIB_FC_SRCS_rt     += kernel/vivosoc3/fll.c 
PULP_LIB_FC_SRCS_rt     += kernel/vivosoc3/freq.c
endif


PULP_LIB_FC_SRCS_rt += kernel/cluster.c

ifneq '$(perf_counters)' ''
PULP_LIB_FC_SRCS_rt += kernel/perf.c
endif

ifneq '$(cluster/version)' ''
ifneq '$(event_unit/version)' '1'
PULP_LIB_CL_SRCS_rt += kernel/sync_mc.c
endif
endif


INSTALL_TARGETS += $(INSTALL_DIR)/lib/$(pulp_chip)/$(PULP_LIB_NAME_rt)/crt0.o


ifeq '$(pulp_chip)' 'oprecompkw'

$(INSTALL_DIR)/lib/$(pulp_chip)/$(PULP_LIB_NAME_rt)/crt0.o: $(CONFIG_BUILD_DIR)/$(PULP_LIB_NAME_rt)/fc/kernel/oprecompkw/rt/crt0.o
	install -D $< $@

else

$(INSTALL_DIR)/lib/$(pulp_chip)/$(PULP_LIB_NAME_rt)/crt0.o: $(CONFIG_BUILD_DIR)/$(PULP_LIB_NAME_rt)/fc/kernel/$(fc_archi)/rt/crt0.o
	install -D $< $@

endif
