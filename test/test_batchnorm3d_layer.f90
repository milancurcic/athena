program test_batchnorm3d_layer
  use athena, only: &
     batchnorm3d_layer_type, &
     base_layer_type, &
     learnable_layer_type
  implicit none

  class(base_layer_type), allocatable :: bn_layer, bn_layer1, bn_layer2
  integer, parameter :: num_channels = 3, width = 8, batch_size = 1
  real, parameter :: gamma  = 0.5, beta = 0.3
  real, allocatable, dimension(:,:,:,:,:) :: input_data, output, gradient
  real, allocatable, dimension(:) :: output_1d
  real, allocatable, dimension(:,:) :: output_2d
  real, parameter :: tol = 0.5E-3
  logical :: success = .true.

  integer :: i, j, output_width
  integer :: seed_size = 1
  real :: mean, std
  integer, allocatable, dimension(:) :: seed
  real, parameter :: max_value = 3.0

  !! Initialize random number generator with a seed
  call random_seed(size = seed_size)
  allocate(seed(seed_size), source=0)
  call random_seed(put = seed)

  !! set up batchnorm3d layer
  bn_layer = batchnorm3d_layer_type( &
     input_shape = [width, width, width, num_channels], &
     batch_size = batch_size, &
     momentum = 0.0, &
     epsilon = 1e-5, &
     gamma_init_mean = (gamma), &
     gamma_init_std = 0.0, &
     beta_init_mean = beta, &
     beta_init_std = 0.0, &
     kernel_initialiser = 'gaussian', &
     bias_initialiser = 'gaussian', &
     moving_mean_initialiser = 'zeros', &
      moving_variance_initialiser = 'zeros' &
     )

  !! check layer name
  if(.not. bn_layer%name .eq. 'batchnorm3d')then
    success = .false.
    write(0,*) 'batchnorm3d layer has wrong name'
  end if

  !! check layer type
  select type(bn_layer)
  type is(batchnorm3d_layer_type)
    !! check input shape
    if(any(bn_layer%input_shape .ne. [width,width,width,num_channels]))then
      success = .false.
      write(0,*) 'batchnorm3d layer has wrong input_shape'
    end if

    !! check output shape
    if(any(bn_layer%output_shape .ne. [width,width,width,num_channels]))then
      success = .false.
      write(0,*) 'batchnorm3d layer has wrong output_shape'
    end if

    !! check batch size
    if(bn_layer%batch_size .ne. 1)then
      success = .false.
      write(0,*) 'batchnorm3d layer has wrong batch size'
    end if
  class default
    success = .false.
    write(0,*) 'batchnorm3d layer has wrong type'
  end select

!!!-----------------------------------------------------------------------------

  !! initialise sample input
  allocate(input_data(width,width,width,num_channels,batch_size), source = 0.0)
  
   input_data = max_value

  !! run forward pass
  call bn_layer%forward(input_data)
  call bn_layer%get_output(output)

  !! check outputs all get normalised to zero
  if (any(output-beta.gt. tol)) then
    success = .false.
    write(0,*) 'batchnorm3d layer forward pass failed: &
         &output should all equal beta'
  end if

!!!-----------------------------------------------------------------------------

  !! initialise sample input
  call random_number(input_data)

  !! run forward pass
  call bn_layer%forward(input_data)
  call bn_layer%get_output(output)

  !! check outputs all get normalised to zero
  do i = 1, num_channels
     mean = sum(output(:,:,:,i,:))/(width**3*batch_size)
     std = sqrt(sum((output(:,:,:,i,:) - mean)**2)/(width**3*batch_size))
     if (abs(mean - beta) .gt. tol) then
       success = .false.
       write(0,*) 'batchnorm3d layer forward pass failed: &
            &mean should equal beta'
     end if
     if (abs(std - gamma) .gt. tol) then
       success = .false.
       write(0,*) 'batchnorm3d layer forward pass failed: &
            &std should equal gamma'
     end if
  end do

  !! run backward pass
  allocate(gradient, source = output)
  call bn_layer%backward(input_data, gradient)

  !! check gradient has expected value
  select type(current => bn_layer)
  type is(batchnorm3d_layer_type)
    do i = 1, num_channels
      mean = sum(current%di(:,:,:,i,:))/(width**3*batch_size)
      std = sqrt(sum((current%di(:,:,:,i,:) - mean)**2)/(width**3*batch_size))
      if (abs(mean) .gt. tol) then
        success = .false.
        write(0,*) 'batchnorm3d layer backward pass failed: &
             &mean gradient should be zero'
      end if
      if (abs(std) .gt. tol) then
        success = .false.
        write(0,*) 'batchnorm3d layer backward pass failed: &
             &std gradient should equal gamma'
      end if
      if (abs(current%db(i) - sum(gradient(:,:,:,i,:))) .gt. tol) then
        success = .false.
        write(0,*) 'batchnorm3d layer backward pass failed: &
             &std gradient should equal sum of gradients'
      end if
    end do
  end select


!!!-----------------------------------------------------------------------------
!!! check layer operations
!!!-----------------------------------------------------------------------------
  bn_layer1 = batchnorm3d_layer_type(input_shape=[2,2,2,1], batch_size=1)
  bn_layer2 = batchnorm3d_layer_type(input_shape=[2,2,2,1], batch_size=1)
  select type(bn_layer1)
  type is(batchnorm3d_layer_type)
     bn_layer1%dg = 1.E0
     bn_layer1%db = 1.E0
     select type(bn_layer2)
     type is(batchnorm3d_layer_type)
        bn_layer2%dg = 2.E0
        bn_layer2%db = 2.E0
        bn_layer = bn_layer1 + bn_layer2
        select type(bn_layer)
        type is(batchnorm3d_layer_type)
           !! check layer addition
           call compare_batchnorm3d_layers(&
                bn_layer, bn_layer1, success, bn_layer2)

           !! check layer reduction
           bn_layer = bn_layer1
           call bn_layer%reduce(bn_layer2)
           call compare_batchnorm3d_layers(&
                bn_layer, bn_layer1, success, bn_layer2)

           !! check layer merge
           bn_layer = bn_layer1
           call bn_layer%merge(bn_layer2)
           call compare_batchnorm3d_layers(&
                bn_layer, bn_layer1, success, bn_layer2)
        class default
            success = .false.
            write(0,*) 'batchnorm3d layer has wrong type'
        end select
     class default
        success = .false.
        write(0,*) 'batchnorm3d layer has wrong type'
     end select
  class default
     success = .false.
     write(0,*) 'batchnorm3d layer has wrong type'
  end select

  !! check 1d and 2d output are consistent
  call bn_layer%get_output(output_1d)
  call bn_layer%get_output(output_2d)
  if(any(abs(output_1d - reshape(output_2d, [size(output_2d)])) .gt. 1.E-6))then
     success = .false.
     write(0,*) 'output_1d and output_2d are not consistent'
  end if

!!!-----------------------------------------------------------------------------
!!! check for any failed tests
!!!-----------------------------------------------------------------------------
  write(*,*) "----------------------------------------"
  if(success)then
     write(*,*) 'test_batchnorm3d_layer passed all tests'
  else
     write(0,*) 'test_batchnorm3d_layer failed one or more tests'
     stop 1
  end if

  contains

  subroutine compare_batchnorm3d_layers(layer1, layer2, success, layer3)
     type(batchnorm3d_layer_type), intent(in) :: layer1, layer2
     logical, intent(inout) :: success
     type(batchnorm3d_layer_type), optional, intent(in) :: layer3

     if(present(layer3))then
        if(any(abs(layer1%dg-layer2%dg-layer3%dg).gt.tol))then
           success = .false.
           write(0,*) 'batchnorm3d layer has wrong gradients'
        end if
        if(any(abs(layer1%db-layer2%db-layer3%db).gt.tol))then
           success = .false.
           write(0,*) 'batchnorm3d layer has wrong gradients'
        end if
     end if

  end subroutine compare_batchnorm3d_layers

end program test_batchnorm3d_layer