##########################################
# CODE DIRECTORIES AND FILES
##########################################
mkfile_path := $(abspath $(firstword $(MAKEFILE_LIST)))
mkfile_dir := $(dir $(mkfile_path))
BIN_DIR := ./bin
SRC_DIR := ./src
LIB_DIR := ./lib
BUILD_DIR = ./obj
LIBS := mod_constants.f90 \
	mod_random.f90 \
	mod_types.f90 \
	mod_misc_ml.f90 \
	mod_activation_gaussian.f90 \
	mod_activation_linear.f90 \
	mod_activation_piecewise.f90 \
	mod_activation_relu.f90 \
	mod_activation_leaky_relu.f90 \
	mod_activation_sigmoid.f90 \
	mod_activation_tanh.f90 \
	mod_activation_none.f90 \
	mod_initialiser_glorot.f90 \
	mod_initialiser_he.f90 \
	mod_initialiser_lecun.f90 \
	mod_initialiser_zeros.f90 \
	mod_misc.f90 \
	mod_activation.f90 \
	mod_initialiser.f90 \
	mod_tools_infile.f90 \
	mod_normalisation.f90 \
	mod_batch_norm.f90 \
	mod_loss_categorical.f90
OBJS := $(addprefix $(LIB_DIR)/,$(LIBS))
#$(info VAR is $(OBJS))
SRCS := inputs.f90 \
	convolution.f90 \
	pooling.f90 \
	fullyconnected.f90 \
	softmax.f90
MAIN := main.f90
SRCS := $(OBJS) $(SRCS) $(MAIN)
OBJS := $(addprefix $(SRC_DIR)/,$(SRCS))


##########################################
# COMPILER CHOICE SECTION
##########################################
FC=gfortran
ifeq ($(FC), $(filter $(FC), "ifort" "ifx"))
	PPFLAGS = -cpp
	MPFLAGS = -qopenmp
	MODULEFLAGS = -module
	DEVFLAGS = -check all -warn #all
	DEBUGFLAGS = -check all -fpe0 -warn -tracekback -debug extended # -check bounds
	OPTIMFLAGS = -O3
else
	PPFLAGS = -cpp
	MPFLAGS = -fopenmp
	MODULEFLAGS = -J
	WARNFLAGS = -Wall
	DEVFLAGS = -g -fbacktrace -fcheck=all -fbounds-check -fsanitize=address -Og #-g -static -ffpe-trap=invalid
	DEBUGFLAGS = -fbounds-check
	MEMFLAGS = -mcmodel=large
	OPTIMFLAGS = -O3 -march=native
endif


##########################################
# LAPACK SECTION
##########################################
MKLROOT?="/usr/local/intel/parallel_studio_xe_2017/compilers_and_libraries_2017/linux/mkl/lib/intel64_lin"
LLAPACK = $(MKLROOT)/libmkl_lapack95_lp64.a \
	-Wl,--start-group \
	$(MKLROOT)/libmkl_intel_lp64.a \
	$(MKLROOT)/libmkl_sequential.a \
	$(MKLROOT)/libmkl_core.a \
	-Wl,--end-group \
	-lpthread

#$(MKLROOT)/libmkl_scalapack_lp64.a \
#$(MKLROOT)/libmkl_solver_lp64_sequential.a \


##########################################
# COMPILATION SECTION
##########################################
INSTALL_DIR?=$(HOME)/bin
NAME = cnn_dev

CFLAGS =


ifeq ($(findstring bigmem,$(MAKECMDGOALS)),bigmem)
	CFLAGS+=$(MEMFLAGS)
endif
ifeq ($(findstring debug,$(MAKECMDGOALS)),debug)
	CFLAGS+=$(DEBUGFLAGS)
endif
ifeq ($(findstring dev,$(MAKECMDGOALS)),dev)
	CFLAGS+=$(DEVFLAGS)
endif
ifeq ($(findstring mp,$(MAKECMDGOALS)),mp)
	CFLAGS+=$(MPFLAGS)
	NAME:=$(NAME)_mp
endif
ifeq ($(findstring memcheck,$(MAKECMDGOALS)),memcheck)
	CFLAGS:=$(filter-out -fsanitize=address, $(CFLAGS))
	CFLAGS:=$(filter-out -Og, $(CFLAGS))
	CFLAGS+=-fsanitize=leak
endif
ifeq ($(findstring optim,$(MAKECMDGOALS)),optim)
	CFLAGS+=$(OPTIMFLAGS)
endif


.PHONY: all install build uninstall clean #mp debug dev optim memcheck bigmem

programs = $(BIN_DIR)/$(NAME)
all: $(programs)


build: all
	@:

%:
	@:
#	$(FC) $(PPFLAGS) $(CFLAGS) $(MODULEFLAGS) $(BUILD_DIR) $(OBJS) -o $(programs)

$(BIN_DIR):
	mkdir -p $@

$(BUILD_DIR):
	mkdir -p $@

$(programs): $(OBJS) | $(BIN_DIR) $(BUILD_DIR)
	$(FC) $(PPFLAGS) $(CFLAGS) $(MODULEFLAGS) $(BUILD_DIR) $(OBJS) -o $@

install: $(OBJS) | $(INSTALL_DIR) $(BUILD_DIR)
	$(FC) $(PPFLAGS) $(CFLAGS) $(MODULEFLAGS) $(BUILD_DIR) $(OBJS) -o $(programs)

clean: 
	rm -rf $(BUILD_DIR)/ $(BIN_DIR)/

uninstall: $(INSTALL_DIR)/$(NAME)
	rm $(INSTALL_DIR)/$(NAME)
