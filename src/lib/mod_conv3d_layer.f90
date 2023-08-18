!!!#############################################################################
!!! Code written by Ned Thaddeus Taylor
!!! Code part of the ARTEMIS group (Hepplestone research group)
!!! Think Hepplestone, think HRG
!!!#############################################################################
module conv3d_layer
  use constants, only: real12
  use base_layer, only: learnable_layer_type
  use custom_types, only: activation_type, initialiser_type, clip_type
  implicit none
  
  
  type, extends(learnable_layer_type) :: conv3d_layer_type
     !! knl = kernel
     !! stp = stride (step)
     !! hlf = half
     !! pad = pad
     !! cen = centre
     !! output_shape = dimension (height, width, depth)
     logical :: calc_input_gradients = .true.
     integer, dimension(3) :: knl, stp, hlf, pad, cen
     integer :: num_channels
     integer :: num_filters
     type(clip_type) :: clip
     real(real12), allocatable, dimension(:) :: bias, bias_incr
     real(real12), allocatable, dimension(:) :: db ! bias gradient
     real(real12), allocatable, dimension(:,:,:,:,:) :: weight, weight_incr
     real(real12), allocatable, dimension(:,:,:,:,:) :: dw ! weight gradient
     real(real12), allocatable, dimension(:,:,:,:) :: output, z
     real(real12), allocatable, dimension(:,:,:,:) :: di ! input gradient
     class(activation_type), allocatable :: transfer
   contains
     procedure, pass(this) :: forward  => forward_rank
     procedure, pass(this) :: backward => backward_rank
     procedure, pass(this) :: update
     procedure, private, pass(this) :: forward_4d
     procedure, private, pass(this) :: backward_4d
  end type conv3d_layer_type

  
!!!-----------------------------------------------------------------------------
!!! interface for layer set up
!!!-----------------------------------------------------------------------------
  interface conv3d_layer_type
     module function layer_setup( &
          input_shape, &
          num_filters, kernel_size, stride, padding, &
          activation_function, activation_scale, &
          kernel_initialiser, bias_initialiser) result(layer)
       integer, dimension(:), intent(in) :: input_shape
       integer, optional, intent(in) :: num_filters
       integer, dimension(..), optional, intent(in) :: kernel_size
       integer, dimension(..), optional, intent(in) :: stride
       real(real12), optional, intent(in) :: activation_scale
       character(*), optional, intent(in) :: activation_function, &
            kernel_initialiser, bias_initialiser, padding
       type(conv3d_layer_type) :: layer
     end function layer_setup
  end interface conv3d_layer_type


  private
  public :: conv3d_layer_type


contains

!!!#############################################################################
!!! forward propagation assumed rank handler
!!!#############################################################################
  pure subroutine forward_rank(this, input)
    implicit none
    class(conv3d_layer_type), intent(inout) :: this
    real(real12), dimension(..), intent(in) :: input

    select rank(input); rank(4)
       call forward_4d(this, input)
    end select
  end subroutine forward_rank
!!!#############################################################################


!!!#############################################################################
!!! backward propagation assumed rank handler
!!!#############################################################################
  pure subroutine backward_rank(this, input, gradient)
    implicit none
    class(conv3d_layer_type), intent(inout) :: this
    real(real12), dimension(..), intent(in) :: input
    real(real12), dimension(..), intent(in) :: gradient

    select rank(input); rank(4)
    select rank(gradient); rank(4)
       call backward_4d(this, input, gradient)
    end select
    end select    
  end subroutine backward_rank
!!!#############################################################################


!!!##########################################################################!!!
!!! * * * * * * * * * * * * * * * * * *  * * * * * * * * * * * * * * * * * * !!!
!!!##########################################################################!!!


!!!#############################################################################
!!! set up and initialise network layer
!!!#############################################################################
  module function layer_setup( &
       input_shape, &
       num_filters, kernel_size, stride, padding, &
       activation_function, activation_scale, &
       kernel_initialiser, bias_initialiser, &
       calc_input_gradients, &
       clip_dict, clip_min, clip_max, clip_norm) result(layer)
    !! add in clipping/constraint options
    !! add in dilation
    !! add in padding handler
    use activation,  only: activation_setup
    use initialiser, only: initialiser_setup
    use misc_ml, only: set_padding
    implicit none
    integer, dimension(:), intent(in) :: input_shape
    integer, optional, intent(in) :: num_filters
    integer, dimension(..), optional, intent(in) :: kernel_size
    integer, dimension(..), optional, intent(in) :: stride
    real(real12), optional, intent(in) :: activation_scale
    character(*), optional, intent(in) :: activation_function, &
         kernel_initialiser, bias_initialiser, padding
    logical, optional, intent(in) :: calc_input_gradients
    type(clip_type), optional, intent(in) :: clip_dict
    real(real12), optional, intent(in) :: clip_min, clip_max, clip_norm

    type(conv3d_layer_type) :: layer

    integer :: i
    real(real12) :: scale
    character(len=10) :: t_activation_function, initialiser_name
    character(len=20) :: t_padding
    class(initialiser_type), allocatable :: initialiser

    integer, dimension(3) :: end_idx


    !!--------------------------------------------------------------------------
    !! set up clipping limits
    !!--------------------------------------------------------------------------
    if(present(clip_dict))then
       layer%clip = clip_dict
       if(present(clip_min).or.present(clip_max).or.present(clip_norm))then
          write(*,*) "Multiple clip options provided to conv3d layer"
          write(*,*) "Ignoring all bar clip_dict"
       end if
    else
       if(present(clip_min))then
          layer%clip%l_min_max = .true.
          layer%clip%min = clip_min
       end if
       if(present(clip_max))then
          layer%clip%l_min_max = .true.
          layer%clip%max = clip_max
       end if
       if(present(clip_norm))then
          layer%clip%l_norm = .true.
          layer%clip%norm = clip_norm
       end if
    end if


    !!--------------------------------------------------------------------------
    !! set up number of filters
    !!--------------------------------------------------------------------------
    if(present(calc_input_gradients))then
       layer%calc_input_gradients = calc_input_gradients
       write(*,*) "CV input gradients turned off"
    else
       layer%calc_input_gradients = .true.
    end if


    !!--------------------------------------------------------------------------
    !! set up number of filters
    !!--------------------------------------------------------------------------
    if(present(num_filters))then
       layer%num_filters = num_filters
    else
       layer%num_filters = 32
    end if
    
    
    !!--------------------------------------------------------------------------
    !! set up kernel size
    !!--------------------------------------------------------------------------
    if(present(kernel_size))then
       select rank(kernel_size)
       rank(0)
          layer%knl = kernel_size
       rank(1)
          layer%knl(1) = kernel_size(1)
          if(size(kernel_size,dim=1).eq.1)then
             layer%knl(2:) = kernel_size(1)
          elseif(size(kernel_size,dim=1).eq.3)then
             layer%knl(2:) = kernel_size(2:)
          end if
       end select
    else
       layer%knl = 3
    end if
    !! odd or even kernel/filter size
    !!--------------------------------------------------------------------------
    layer%cen = 2 - mod(layer%knl, 2)
    layer%hlf   = (layer%knl-1)/2

    if(present(padding))then
       t_padding = padding
    else
       t_padding = "valid"
    end if
    do i=1,3
       call set_padding(layer%pad(i), layer%knl(i), t_padding)
    end do


    !!--------------------------------------------------------------------------
    !! set up stride
    !!--------------------------------------------------------------------------
    if(present(stride))then
       select rank(stride)
       rank(0)
          layer%stp = stride
       rank(1)
          layer%stp(1) = stride(1)
          if(size(stride,dim=1).eq.1)then
             layer%stp(2:) = stride(1)
          elseif(size(stride,dim=1).eq.3)then
             layer%stp(2:) = stride(2:)
          end if
       end select
    else
       layer%stp = 1
    end if
    

    !!--------------------------------------------------------------------------
    !! set activation and derivative functions based on input name
    !!--------------------------------------------------------------------------
    if(present(activation_function))then
       t_activation_function = activation_function
    else
       t_activation_function = "none"
    end if
    if(present(activation_scale))then
       scale = activation_scale
    else
       scale = 1._real12
    end if
    write(*,'("CV activation function: ",A)') trim(t_activation_function)
    allocate(layer%transfer, &
         source=activation_setup(t_activation_function, scale))


    !!--------------------------------------------------------------------------
    !! allocate output, activation, bias, and weight shapes
    !!--------------------------------------------------------------------------
    layer%num_channels = input_shape(4)
    layer%input_shape  = input_shape
!!! WARNING, TAKE IN WHAT IS ALREADY IN THE PADDING
!!! THEN JUST SUBTRACT THE PADDING (or no need
    layer%output_shape = floor((input_shape + 2.0 * layer%pad - layer%knl)/&
         real(layer%stp) ) + 1

    allocate(layer%output(&
         layer%output_shape(1),layer%output_shape(2),layer%output_shape(3),&
         layer%num_filters))
    allocate(layer%z, mold=layer%output)
    layer%z = 0._real12

    allocate(layer%bias(layer%num_filters))

    end_idx   = layer%hlf + (layer%cen - 1)
    allocate(layer%weight(&
         -layer%hlf(1):end_idx(1),&
         -layer%hlf(2):end_idx(2),&
         -layer%hlf(3):end_idx(3),&
         layer%num_channels,layer%num_filters))


    !!--------------------------------------------------------------------------
    !! initialise weights and biases steps (velocities)
    !!--------------------------------------------------------------------------
    allocate(layer%bias_incr, mold=layer%bias)
    allocate(layer%weight_incr, mold=layer%weight)
    layer%bias_incr = 0._real12
    layer%weight_incr = 0._real12


    !!--------------------------------------------------------------------------
    !! initialise gradients
    !!--------------------------------------------------------------------------
    allocate(layer%di(&
         input_shape(1), input_shape(2), input_shape(3), input_shape(4)), &
         source=0._real12)
    allocate(layer%dw, mold=layer%weight)
    allocate(layer%db, mold=layer%bias)
    layer%di = 0._real12
    layer%dw = 0._real12
    layer%db = 0._real12


    !!--------------------------------------------------------------------------
    !! initialise weights (kernels)
    !!--------------------------------------------------------------------------
    if(present(kernel_initialiser))then
       initialiser_name = kernel_initialiser
    elseif(trim(t_activation_function).eq."selu")then
       initialiser_name = "lecun_normal"
    elseif(index(t_activation_function,"elu").ne.0)then
       initialiser_name = "he_uniform"
    else
       initialiser_name = "glorot_uniform"
    end if
    write(*,'("CV kernel initialiser: ",A)') initialiser_name
    allocate(initialiser, source=initialiser_setup(initialiser_name))
    call initialiser%initialise(layer%weight, &
         fan_in=product(layer%knl)+1, fan_out=1)
    deallocate(initialiser)

    !! initialise biases
    !!--------------------------------------------------------------------------
    if(present(bias_initialiser))then
       initialiser_name = bias_initialiser
    else
       initialiser_name= "zeros"
    end if
    write(*,'("CV bias initialiser: ",A)') initialiser_name
    allocate(initialiser, source=initialiser_setup(initialiser_name))
    call initialiser%initialise(layer%bias, &
         fan_in=product(layer%knl)+1, fan_out=1)

  end function layer_setup
!!!#############################################################################


!!!#############################################################################
!!! forward propagation
!!!#############################################################################
  pure subroutine forward_4d(this, input)
    implicit none
    class(conv3d_layer_type), intent(inout) :: this
    real(real12), &
         dimension(-this%pad(1)+1:,-this%pad(2)+1:,-this%pad(3)+1:,:), &
         intent(in) :: input

    integer :: i, j, k, l
    integer, dimension(3) :: stp_idx, start_idx, end_idx


    !! perform the convolution operation
    !!--------------------------------------------------------------------------
    do concurrent(i=1:this%output_shape(1):1, j=1:this%output_shape(2):1, k=1:this%output_shape(3):1)
       stp_idx(1) = (i-1)*this%stp(1) + 1 + (this%hlf(1) - this%pad(1))
       stp_idx(2) = (j-1)*this%stp(2) + 1 + (this%hlf(2) - this%pad(2))
       stp_idx(3) = (k-1)*this%stp(3) + 1 + (this%hlf(3) - this%pad(3))
       start_idx  = stp_idx - this%hlf
       end_idx    = start_idx + this%knl - 1

       this%z(i,j,k,:) = this%bias(:)

       do concurrent(l=1:this%num_filters)
          this%z(i,j,k,l) = this%z(i,j,k,l) + &
               sum( &
               input(&
               start_idx(1):end_idx(1),&
               start_idx(2):end_idx(2),&
               start_idx(3):end_idx(3),:) * &
               this%weight(:,:,:,:,l) &
               )
       end do
    end do
    
    !! apply activation function to activation values (z)
    !!--------------------------------------------------------------------------
    this%output = this%transfer%activate(this%z) 

  end subroutine forward_4d
!!!#############################################################################


!!!#############################################################################
!!! backward propagation
!!! method : gradient descent
!!!#############################################################################
  pure subroutine backward_4d(this, input, gradient)
    implicit none
    class(conv3d_layer_type), intent(inout) :: this
    real(real12), &
         dimension(-this%pad(1)+1:,-this%pad(2)+1:,-this%pad(3)+1:,:), &
         intent(in) :: input
    real(real12), &
         dimension(&
         this%output_shape(1),&
         this%output_shape(2),&
         this%output_shape(3),this%num_filters), &
         intent(in) :: gradient


    !! NOTE: lim_w is rotated by 180, so first idx is end, then start
    !! ... i.e. lim_w(1,:) = ends
    !! ... i.e. lim_w(2,:) = starts
    integer :: l, m, i, j, k, x, y, z
    integer, dimension(3) :: stp_idx, offset, end_idx, n_stp
    integer, dimension(2,3) :: lim, lim_w, lim_g
    real(real12), dimension(&
         lbound(this%di,1):ubound(this%di,1),&
         lbound(this%di,2):ubound(this%di,2),&
         lbound(this%di,3):ubound(this%di,3),this%num_channels) :: di
    real(real12), &
         dimension(&
         this%output_shape(1),&
         this%output_shape(2),&
         this%output_shape(3),this%num_filters) :: grad_dz


    real(real12), dimension(1) :: bias_diff
    bias_diff = this%transfer%differentiate([1._real12])


    !! get size of the input and output feature maps
    !!--------------------------------------------------------------------------
    end_idx = this%hlf + (this%cen - 1)
    offset  = 1 + this%hlf - this%pad


    !! get gradient multiplied by differential of Z
    !!--------------------------------------------------------------------------
    grad_dz = 0._real12
    grad_dz(&
         1:this%output_shape(1),&
         1:this%output_shape(2),&
         1:this%output_shape(3),:) = gradient * &
         this%transfer%differentiate(this%z)
    do concurrent(l=1:this%num_filters)
       this%db(l) = this%db(l) + sum(grad_dz(:,:,:,l)) * bias_diff(1)
    end do

    !! apply convolution to compute weight gradients
    !! offset applied as centre of kernel is 0 ...
    !! ... whilst the starting index for input is 1
    !!--------------------------------------------------------------------------
    do concurrent( &
         z=-this%hlf(3):end_idx(3):1, &
         y=-this%hlf(2):end_idx(2):1, &
         x=-this%hlf(1):end_idx(1):1, &
         m=1:this%num_channels, &
         l=1:this%num_filters &
         )
       this%dw(x,y,z,m,l) = this%dw(x,y,z,m,l) + &
            sum(grad_dz(:,:,:,l) * &
            input(&
            x+offset(1):x+offset(1)-2 + ubound(input,dim=1):this%stp(1), &
            y+offset(2):y+offset(2)-2 + ubound(input,dim=2):this%stp(2), &
            z+offset(3):z+offset(3)-2 + ubound(input,dim=3):this%stp(3),m))
    end do


    !! apply strided convolution to obtain input gradients
    !!--------------------------------------------------------------------------
    if(this%calc_input_gradients)then
       lim(1,:) = this%knl - 1
       lim(2,:) = (this%output_shape - 1) * this%stp + 1 + end_idx
       n_stp = this%output_shape * this%stp
       this%di = 0._real12
       !! all elements of the output are separated by stride_x (stride_y)
       do concurrent( &
            i=1:size(this%di,dim=1):1, &
            j=1:size(this%di,dim=2):1, &
            k=1:size(this%di,dim=3):1, &
            m=1:this%num_channels, &
            l=1:this%num_filters &
            )

          stp_idx = ([i,j,k]-offset)/this%stp + 1
          !! max( ...
          !! ... 1. offset of 1st o/p idx from centre of knl     (lim)
          !! ... 2. lwst o/p idx overlap with <<- knl idx (rpt. pattern)
          !! ...)
          lim_w(2,:) = max(lim(1,:)-[i,j,k],  -this%hlf + &
               mod(n_stp+this%knl-[i,j,k],this%stp))
          !! min( ...
          !! ... 1. offset of last o/p idx from centre of knl    (lim)
          !! ... 2. hghst o/p idx overlap with ->> knl idx (rpt. pattern)
          !! ...)
          lim_w(1,:) = min(lim(2,:)-[i,j,k], end_idx - &
               mod(n_stp-1+[i,j,k],this%stp))
          if(any(lim_w(2,:).gt.lim_w(1,:))) cycle


          lim_g(1,:) = max(1,                 stp_idx)
          lim_g(2,:) = min(this%output_shape, stp_idx + ([i,j,k]-1)/this%stp )

          !! apply full convolution to compute input gradients
          !! https://medium.com/@mayank.utexas/backpropagation-for-convolution-with-strides-8137e4fc2710
          this%di(i,j,k,m) = &
               this%di(i,j,k,m) + &
               sum( &
               grad_dz(&
               lim_g(1,1):lim_g(2,1),&
               lim_g(1,2):lim_g(2,2),&
               lim_g(1,3):lim_g(2,3),l) * &
               this%weight(&
               lim_w(1,1):lim_w(2,1):-this%stp(1),&
               lim_w(1,2):lim_w(2,2):-this%stp(2),&
               lim_w(1,3):lim_w(2,3):-this%stp(3),m,l) )

       end do
    end if

  end subroutine backward_4d
!!!#############################################################################


!!!#############################################################################
!!! update the weights based on how much error the node is responsible for
!!!#############################################################################
  pure subroutine update(this, optimiser, batch_size)
    use optimiser, only: optimiser_type
    use normalisation, only: gradient_clip
    implicit none
    class(conv3d_layer_type), intent(inout) :: this
    type(optimiser_type), intent(in) :: optimiser
    integer, optional, intent(in) :: batch_size

    integer :: l

    
    !! normalise by number of samples
    if(present(batch_size))then
       this%dw = this%dw/batch_size
       this%db = this%db/batch_size
    end if

    !! apply gradient clipping
    if(this%clip%l_min_max.or.this%clip%l_norm)then
       do l=1,size(this%bias,dim=1)
          if(this%clip%l_min_max) call gradient_clip(size(this%dw(:,:,:,:,l)),&
               this%dw(:,:,:,:,l),this%db(l),&
               clip_min=this%clip%min,clip_max=this%clip%max)
          if(this%clip%l_norm) &
               call gradient_clip(size(this%dw(:,:,:,:,l)),&
               this%dw(:,:,:,:,l),this%db(l),&
               clip_norm=this%clip%norm)
       end do
    end if

    !! update the convolution layer weights using gradient descent
    call optimiser%optimise(&
         this%weight,&
         this%weight_incr, &
         this%dw)
    !! update the convolution layer bias using gradient descent
    call optimiser%optimise(&
         this%bias,&
         this%bias_incr, &
         this%db)

    !! reset gradients
    this%di = 0._real12
    this%dw = 0._real12
    this%db = 0._real12

  end subroutine update
!!!#############################################################################


end module conv3d_layer
!!!#############################################################################
