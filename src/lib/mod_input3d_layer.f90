!!!#############################################################################
!!! Code written by Ned Thaddeus Taylor
!!! Code part of the ARTEMIS group (Hepplestone research group)
!!! Think Hepplestone, think HRG
!!!#############################################################################
module input3d_layer
  use constants, only: real12
  use base_layer, only: input_layer_type
  implicit none
  
  
  type, extends(input_layer_type) :: input3d_layer_type
     real(real12), allocatable, dimension(:,:,:,:) :: output
   contains
     procedure, pass(this) :: get_output => get_output_input3d
     procedure, pass(this) :: init => init_input3d
     procedure, pass(this) :: set_batch_size => set_batch_size_input3d
     procedure, pass(this) :: forward  => forward_rank
     procedure, pass(this) :: backward => backward_rank
     procedure, pass(this) :: set => set_input3d
  end type input3d_layer_type

  interface input3d_layer_type
     module function layer_setup(input_shape, batch_size) result(layer)
       integer, dimension(:), optional, intent(in) :: input_shape
       integer, optional, intent(in) :: batch_size 
       type(input3d_layer_type) :: layer
     end function layer_setup
  end interface input3d_layer_type

  
  private
  public :: input3d_layer_type


contains

!!!#############################################################################
!!! get layer outputs
!!!#############################################################################
  pure subroutine get_output_input3d(this, output)
    implicit none
    class(input3d_layer_type), intent(in) :: this
    real(real12), allocatable, dimension(..), intent(out) :: output
  
    select rank(output)
    rank(1)
       output = reshape(this%output, [size(this%output)])
    rank(2)
       output = &
            reshape(this%output, [product(this%output_shape),this%batch_size])
    rank(4)
       output = this%output
    end select
  
  end subroutine get_output_input3d
!!!#############################################################################


!!!##########################################################################!!!
!!! * * * * * * * * * * * * * * * * * *  * * * * * * * * * * * * * * * * * * !!!
!!!##########################################################################!!!


!!!#############################################################################
!!! forward propagation assumed rank handler
!!! placeholder to satisfy deferred
!!!#############################################################################
  pure subroutine forward_rank(this, input)
    implicit none
    class(input3d_layer_type), intent(inout) :: this
    real(real12), dimension(..), intent(in) :: input

    select rank(input)
    rank(1)
       this%output = reshape(input, shape=shape(this%output))
    rank(2)
       this%output = reshape(input, shape=shape(this%output))
    rank(3)
       this%output = reshape(input, shape=shape(this%output))
    rank(4)
       this%output = reshape(input, shape=shape(this%output))
    rank(5)
       this%output = reshape(input, shape=shape(this%output))
    rank(6)
       this%output = reshape(input, shape=shape(this%output))
    end select
  end subroutine forward_rank
!!!#############################################################################


!!!#############################################################################
!!! backward propagation assumed rank handler
!!! placeholder to satisfy deferred
!!!#############################################################################
  pure subroutine backward_rank(this, input, gradient)
    implicit none
    class(input3d_layer_type), intent(inout) :: this
    real(real12), dimension(..), intent(in) :: input
    real(real12), dimension(..), intent(in) :: gradient
    return
  end subroutine backward_rank
!!!#############################################################################


!!!##########################################################################!!!
!!! * * * * * * * * * * * * * * * * * *  * * * * * * * * * * * * * * * * * * !!!
!!!##########################################################################!!!


!!!#############################################################################
!!! set up layer
!!!#############################################################################
#if defined(GFORTRAN)
  module function layer_setup(input_shape, batch_size) result(layer)
    implicit none
    integer, dimension(:), optional, intent(in) :: input_shape
    integer, optional, intent(in) :: batch_size

    type(input3d_layer_type) :: layer
#else
  module procedure layer_setup
    implicit none
#endif


    layer%name = "input3d"
    layer%input_rank = 3
    !!--------------------------------------------------------------------------
    !! initialise batch size
    !!--------------------------------------------------------------------------
    if(present(batch_size)) layer%batch_size = batch_size


    !!--------------------------------------------------------------------------
    !! initialise layer shape
    !!--------------------------------------------------------------------------
    if(present(input_shape)) call layer%init(input_shape=input_shape)

#if defined(GFORTRAN)
  end function layer_setup
#else
  end procedure layer_setup
#endif
!!!#############################################################################


!!!#############################################################################
!!! initialise layer
!!!#############################################################################
  subroutine init_input3d(this, input_shape, batch_size, verbose)
    implicit none
    class(input3d_layer_type), intent(inout) :: this
    integer, dimension(:), intent(in) :: input_shape
    integer, optional, intent(in) :: batch_size
    integer, optional, intent(in) :: verbose

    integer :: t_verb


    !!--------------------------------------------------------------------------
    !! initialise optional arguments
    !!--------------------------------------------------------------------------
    if(present(verbose))then
       t_verb = verbose
    else
       t_verb = 0
    end if
    if(present(batch_size)) this%batch_size = batch_size


    !!--------------------------------------------------------------------------
    !! initialise input shape
    !!--------------------------------------------------------------------------
    if(.not.allocated(this%input_shape)) call this%set_shape(input_shape)
    
    this%output_shape = this%input_shape
    this%num_outputs = product(this%input_shape)

    
    !!--------------------------------------------------------------------------
    !! initialise batch size-dependent arrays
    !!--------------------------------------------------------------------------
    if(this%batch_size.gt.0) call this%set_batch_size(this%batch_size)

  end subroutine init_input3d
!!!#############################################################################


!!!#############################################################################
!!! set batch size
!!!#############################################################################
  subroutine set_batch_size_input3d(this, batch_size, verbose)
    implicit none
    class(input3d_layer_type), intent(inout) :: this
    integer, intent(in) :: batch_size
    integer, optional, intent(in) :: verbose

    integer :: t_verb


    !!--------------------------------------------------------------------------
    !! initialise optional arguments
    !!--------------------------------------------------------------------------
    if(present(verbose))then
       t_verb = verbose
    else
       t_verb = 0
    end if
    this%batch_size = batch_size


    !!--------------------------------------------------------------------------
    !! allocate arrays
    !!--------------------------------------------------------------------------
    if(allocated(this%input_shape))then
       if(allocated(this%output)) deallocate(this%output)
       allocate(this%output( &
           this%input_shape(1), &
           this%input_shape(2), &
           this%input_shape(3), &
           this%batch_size))
    end if

  end subroutine set_batch_size_input3d
!!!#############################################################################


!!!##########################################################################!!!
!!! * * * * * * * * * * * * * * * * * *  * * * * * * * * * * * * * * * * * * !!!
!!!##########################################################################!!!


!!!#############################################################################
!!! set input layer values
!!!#############################################################################
  pure subroutine set_input3d(this, input)
    implicit none
    class(input3d_layer_type), intent(inout) :: this
    real(real12), &
         dimension(this%batch_size * this%num_outputs), intent(in) :: input

    this%output = reshape(input, shape=shape(this%output))
  end subroutine set_input3d
!!!#############################################################################


end module input3d_layer
!!!#############################################################################
