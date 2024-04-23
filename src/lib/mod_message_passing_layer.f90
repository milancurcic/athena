!!!#############################################################################
!!! Code written by Ned Thaddeus Taylor
!!! Code part of the ATHENA library - a feedforward neural network library
!!!#############################################################################
!!! module contains implementation of a message passing neural network
!!!#############################################################################
module mpnn_module
  use constants, only: real12
  use custom_types, only: graph_type
  implicit none
  

  private

  public :: mpnn_type, feature_type
  public :: state_method_type, message_method_type, readout_method_type
  public :: state_update, get_state_differential
  public :: message_update, get_message_differential
  public :: get_readout_output, get_readout_differential


  type :: mpnn_type
     integer :: num_features
     integer :: num_vertices
     integer :: num_time_steps
     integer :: batch_size
     !! state and message dimension is (time_step)
     class(message_method_type), dimension(:), allocatable :: message
     class(state_method_type), dimension(:), allocatable :: state
     class(readout_method_type), allocatable :: readout
     real(real12), dimension(:,:), allocatable :: output
     real(real12), dimension(:,:,:,:), allocatable :: di
   contains
     procedure, pass(this) :: forward
     procedure, pass(this) :: backward
  end type mpnn_type


  type :: feature_type
     real(real12), dimension(:,:), allocatable :: val
   contains
     ! t = type, r = real, i = int
     procedure :: add_t_t => feature_add
     procedure :: multiply_t_t => feature_multiply
     generic :: operator(+) => add_t_t
     generic :: operator(*) => multiply_t_t
  end type feature_type


   type, abstract :: message_method_type
     integer :: num_features
     integer :: batch_size
     !! feature has dimensions (feature, vertex)
     type(feature_type), dimension(:), allocatable :: feature
     type(feature_type), dimension(:), allocatable :: di
   contains
     procedure(message_update), deferred, pass(this) :: update
     procedure(get_message_differential), deferred, pass(this) :: get_differential
     procedure(calculate_message_partials), deferred, pass(this) :: calculate_partials
  end type message_method_type

  type, abstract :: state_method_type
     integer :: num_features
     integer :: batch_size
     !! feature has dimensions (feature, vertex)
     type(feature_type), dimension(:), allocatable :: feature
     type(feature_type), dimension(:), allocatable :: di
   contains
     procedure(state_update), deferred, pass(this) :: update
     procedure(get_state_differential), deferred, pass(this) :: get_differential
     procedure(calculate_state_partials), deferred, pass(this) :: calculate_partials
  end type state_method_type

  type, abstract :: readout_method_type
     integer :: batch_size
     integer :: num_time_steps
     integer :: num_outputs
   contains
     procedure(get_readout_output), deferred, pass(this) :: get_output
     procedure(get_readout_differential), deferred, pass(this) :: get_differential
     procedure(calculate_readout_partials), deferred, pass(this) :: calculate_partials
  end type readout_method_type


  abstract interface
     subroutine message_update(this, hidden, graph)
       import :: message_method_type, feature_type, graph_type
       class(message_method_type), intent(inout) :: this
       !! hidden features has dimensions (feature, vertex, batch_size)
       type(feature_type), dimension(this%batch_size), intent(in) :: hidden
       type(graph_type), dimension(this%batch_size), intent(in) :: graph
     end subroutine message_update

     pure function get_message_differential(this, hidden, graph) result(output)
       import :: message_method_type, feature_type, graph_type
       class(message_method_type), intent(in) :: this
       !! hidden features has dimensions (feature, vertex, batch_size)
       type(feature_type), dimension(this%batch_size), intent(in) :: hidden
       type(graph_type), dimension(this%batch_size), intent(in) :: graph
       type(feature_type), dimension(this%batch_size) :: output
     end function get_message_differential

     subroutine calculate_message_partials(this, output_state, graph, input)
       import :: message_method_type, state_method_type, feature_type, graph_type
       class(message_method_type), intent(inout) :: this
       !! hidden features has dimensions (feature, vertex, batch_size)
       class(state_method_type), intent(in) :: output_state
       type(graph_type), dimension(this%batch_size), intent(in) :: graph
       type(feature_type), dimension(this%batch_size), intent(in) :: input
     end subroutine calculate_message_partials


     subroutine state_update(this, message, graph)
       import :: state_method_type, feature_type, graph_type
       class(state_method_type), intent(inout) :: this
       !! message has dimensions (feature, vertex, batch_size)
       type(feature_type), dimension(this%batch_size), intent(in) :: message
       type(graph_type), dimension(this%batch_size), intent(in) :: graph
     end subroutine state_update

     pure function get_state_differential(this, message, graph) result(output)
       import :: state_method_type, feature_type, graph_type
       class(state_method_type), intent(in) :: this
       !! message has dimensions (feature, vertex, batch_size)
       type(feature_type), dimension(this%batch_size), intent(in) :: message
       type(graph_type), dimension(this%batch_size), intent(in) :: graph
       type(feature_type), dimension(this%batch_size) :: output
     end function get_state_differential

     subroutine calculate_state_partials(this, output_message, graph, input)
       import :: state_method_type, message_method_type, feature_type, graph_type
       class(state_method_type), intent(inout) :: this
       !! hidden features has dimensions (feature, vertex, batch_size)
       class(message_method_type), intent(in) :: output_message
       type(graph_type), dimension(this%batch_size), intent(in) :: graph
       type(feature_type), dimension(this%batch_size), optional, intent(in) :: input
     end subroutine calculate_state_partials


     function get_readout_output(this, state) result(output)
       import :: readout_method_type, state_method_type, real12
       class(readout_method_type), intent(inout) :: this
       class(state_method_type), dimension(:), intent(in) :: state
       real(real12), dimension(:,:), allocatable :: output
    end function get_readout_output

     pure function get_readout_differential(this, state, gradient) result(output)
       import :: readout_method_type, state_method_type, feature_type, real12
       class(readout_method_type), intent(in) :: this
       class(state_method_type), dimension(:), intent(in) :: state
       real(real12), dimension(:,:), intent(in) :: gradient
       type(feature_type), dimension(this%batch_size) :: output
     end function get_readout_differential

     subroutine calculate_readout_partials(this, input_state, gradient)
       import :: readout_method_type, state_method_type, feature_type, real12
       class(readout_method_type), intent(in) :: this
       class(state_method_type), dimension(:), intent(in) :: input_state
       real(real12), dimension(:,:), intent(in) :: gradient
     end subroutine calculate_readout_partials

  end interface
  

  interface mpnn_type
     module function layer_setup( &
          state_method, message_method, readout_method, &
          num_features, num_vertices, num_time_steps, batch_size &
      ) result(layer)
       !! MAKE THESE ASSUMED RANK
       class(state_method_type), intent(in) :: state_method
       class(message_method_type), intent(in) :: message_method
       class(readout_method_type), intent(in) :: readout_method
       integer, intent(in) :: num_features
       integer, intent(in) :: num_vertices
       integer, intent(in) :: num_time_steps
       integer, optional, intent(in) :: batch_size
       type(mpnn_type) :: layer
     end function layer_setup
  end interface mpnn_type


contains

  elemental function feature_add(a, b) result(output)
    class(feature_type), intent(in) :: a, b
    type(feature_type) :: output

    !allocate(output%val(size(a%val,1), size(a%val,2)))
    output%val = a%val + b%val
  end function feature_add

  elemental function feature_multiply(a, b) result(output)
    class(feature_type), intent(in) :: a, b
    type(feature_type) :: output

    !allocate(output%val(size(a%val,1), size(a%val,2)))
    output%val = a%val * b%val
  end function feature_multiply


!!!#############################################################################
!!! layer setup
!!!#############################################################################
  module function layer_setup( &
       state_method, message_method, readout_method, &
       num_features, num_vertices, num_time_steps, batch_size &
   ) result(layer)
    implicit none
    type(mpnn_type) :: layer
    class(state_method_type), intent(in) :: state_method
    class(message_method_type), intent(in) :: message_method
    class(readout_method_type), intent(in) :: readout_method
    integer, intent(in) :: num_features
    integer, intent(in) :: num_vertices
    integer, intent(in) :: num_time_steps
    integer, optional, intent(in) :: batch_size

    integer :: i

    layer%num_features = num_features
    layer%num_vertices = num_vertices
    layer%num_time_steps = num_time_steps
    if (present(batch_size)) then
       layer%batch_size = batch_size
    else
       layer%batch_size = 1
    end if

    layer%readout = readout_method
    allocate(layer%output(num_features * num_vertices, layer%batch_size))
    allocate(layer%di(num_features, num_vertices, num_time_steps, layer%batch_size))

    allocate(layer%state(num_time_steps))
    allocate(layer%message(num_time_steps))
    do i = 1, num_time_steps
       allocate(layer%state(i), source = state_method)
       allocate(layer%message(i), source = message_method)
    end do

  end function layer_setup
!!!#############################################################################


!!!#############################################################################
!!! forward propagation
!!!#############################################################################
  subroutine forward(this, graph)
    implicit none
    class(mpnn_type), intent(inout) :: this
    type(graph_type), dimension(this%batch_size), intent(in) :: graph

    integer :: v, s, t

    do s = 1, this%batch_size
       do v = 1, this%num_vertices
          this%state(1)%feature(s)%val(:,v) = graph(s)%vertex(v)%feature
       end do
    end do
    do t = 1, this%num_time_steps
       call this%message(t)%update(this%state(t)%feature, graph)
       call this%state(t)%update(this%message(t+1)%feature, graph)
    end do

    this%output = this%readout%get_output(this%state)

  end subroutine forward
!!!#############################################################################


!!!#############################################################################
!!! backpropagation
!!!#############################################################################
  subroutine backward(this, graph, gradient)
    implicit none
    class(mpnn_type), intent(inout) :: this
    type(graph_type), dimension(this%batch_size), intent(in) :: graph
    real(real12), dimension( &
         this%readout%num_outputs, &
         this%batch_size &
    ), intent(in) :: gradient

    integer :: s, t

    !df/dv_c = h(M_c) * df/dM_y

    ! M_y = sum_c v_c * h(M_c)     message for output y
    ! h()                          hidden function

    this%state(this%num_time_steps)%di = &
         this%readout%get_differential(this%state, gradient)

    do t = this%num_time_steps-1, 1, -1
       !! check if time_step t are all handled correctly here
       call this%message(t+1)%calculate_partials( &
            input = this%state(t)%feature, &
            output_state = this%state(t+1), &
            graph = graph &
       )
       !this%message(t+1)%di = this%state(t+1)%di * &
       !      this%state(t+1)%get_differential( &
       !          this%message(t+1)%feature, graph &
       !      )
       select case(t)
       case(1)
          call this%state(t)%calculate_partials( &
               input = this%message(t)%feature, &
               output_message = this%message(t+1), &
               graph = graph &
          )
       case default
          call this%state(t)%calculate_partials( &
                output_message = this%message(t+1), &
                graph = graph &
          )
       end select
       !this%state(t)%di = this%message(t+1)%di * &
       !      this%message(t+1)%get_differential( &
       !          this%state(t)%feature, graph &
       !      )

       ! this%di(:,:,t,s) = this%di(:,:,t+1,s) * &
       !       this%state(t+1)%get_differential( &
       !            this%message(t+1)%feature(s)%val(:,:) &
       !       ) * &
       !       this%message(t+1)%get_differential( &
       !            this%state(t)%feature(s)%val(:,:), graph &
       !       )
       
       !! ! this is method dependent
       !! this%dw(:,:,t,s) = this%message(:,t+1,s) * this%v(:,t,s)
    end do

  end subroutine backward
!!!#############################################################################

end module mpnn_module
!!!#############################################################################