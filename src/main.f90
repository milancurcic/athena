!!!#############################################################################
!!! 
!!!#############################################################################
program ConvolutionalNeuralNetwork
#ifdef _OPENMP
  use omp_lib
#endif
  use constants, only: real12
  use misc, only: shuffle
  !use misc_maths, only: mean
  use infile_tools, only: stop_check
  use normalisation, only: linear_renormalise
  use inputs
  use ConvolutionLayer, cv_init => initialise, cv_forward => forward, &
       cv_backward => backward, &
       cv_update => update_weights_and_biases, &
       cv_write => write_file
  use PoolingLayer, pl_init => initialise, pl_forward => forward, &
       pl_backward => backward
  use FullyConnectedLayer, fc_init => initialise, fc_forward => forward, &
       fc_backward => backward, &
       fc_update => update_weights_and_biases, &
       fc_write => write_file
  use SoftmaxLayer, sm_init => initialise, sm_forward => forward, &
       sm_backward => backward

  implicit none

  !! seed variables
  integer :: nseed=1
  integer, allocatable, dimension(:) :: seed_arr

  !! training and testing monitoring
  real(real12) :: accuracy, sum_accuracy, sum_loss, overall_loss
  real(real12) :: exploding_check, exploding_check_old
  real(real12), allocatable, dimension(:) :: loss_history

  !! data loading and preoprocessing
  real(real12), allocatable, dimension(:,:,:,:) :: input_images, test_images
  integer, allocatable, dimension(:) :: labels, test_labels
  character(1024) :: train_file, test_file, cnn_file

  !! neural network size and shape variables
  integer, parameter :: num_classes = 10    ! Number of output classes
  integer :: input_channels  ! Number of input channels (i.e. RGB)
  integer :: image_size, lw_image_size, up_image_size
  integer :: output_size
  integer :: input_size
  integer :: output_channels
  integer :: num_pool
  integer :: fc_num_layers
  integer, allocatable, dimension(:) :: tmp_num_hidden

  !! training loop variables
  integer :: num_batches, num_samples, num_samples_test
  integer :: epoch, batch, sample, start_index, end_index
  integer :: expected
  real(real12), allocatable, dimension(:) :: fc_input, fc_output, sm_output, &
       pl_output_rs
  real(real12), allocatable, dimension(:) :: sm_gradients
  type(network_gradient_type), allocatable, dimension(:) :: fc_gradients, &
       comb_fc_gradients
  real(real12), allocatable, dimension(:,:,:) :: cv_output, pl_output
  real(real12), allocatable, dimension(:,:,:) :: cv_gradients, pl_gradients, &
       fc_gradients_rs
  real(real12), allocatable, dimension(:,:,:) :: comb_cv_gradients

  integer :: i, l, time, time_old, clock_rate, itmp1
  real(real12) :: rtmp1

  real(real12), allocatable, dimension(:,:,:) :: image_sample
#ifdef _OPENMP
  integer, allocatable, dimension(:) :: label_slice
  real(real12), allocatable, dimension(:,:,:,:) :: image_slice
#endif


!!!-----------------------------------------------------------------------------
!!! set up reduction for gradient custom type
!!! ...
!! https://www.openmp.org/spec-html/5.0/openmpsu107.html
!! https://stackoverflow.com/questions/61141297/openmp-reduction-on-user-defined-fortran-type-containing-allocatable-array
!! https://fortran-lang.discourse.group/t/openmp-reduction-on-operator/5887
!!!-----------------------------------------------------------------------------
  !$omp declare reduction(sum_operator:network_gradient_type:gradient_sum(omp_out,omp_in)) &
  !$omp& initializer(omp_priv = omp_orig)


!!!-----------------------------------------------------------------------------
!!! initialise global variables
!!!-----------------------------------------------------------------------------
  call set_global_vars()
#ifdef _OPENMP
  call omp_set_num_threads(num_threads)
#endif


!!!-----------------------------------------------------------------------------
!!! read training dataset
!!!-----------------------------------------------------------------------------
  train_file = '/nutanix/gpshome/ntt203/DCoding/DTest_dir/DMNIST/MNIST_train.txt'
  call read_mnist(train_file,input_images, labels, &
       maxval(cv_kernel_size), image_size, padding_method)
  input_channels = size(input_images, 3)
  output_channels = cv_num_filters * input_channels
  num_samples = size(input_images, 4)
  num_batches = num_samples / batch_size


!!!-----------------------------------------------------------------------------
!!! read testing dataset
!!!-----------------------------------------------------------------------------
  test_file = '/nutanix/gpshome/ntt203/DCoding/DTest_dir/DMNIST/MNIST_test.txt'
  call read_mnist(test_file,test_images, test_labels, &
       maxval(cv_kernel_size), itmp1, padding_method)
  num_samples_test = size(test_images, 4)


!!!-----------------------------------------------------------------------------
!!! initialise monitoring variables
!!!-----------------------------------------------------------------------------
  allocate(loss_history(10))
  loss_history = -huge(1._real12)
  loss_threshold = 2._real12
  if(batch_learning)then
     exploding_check = 0._real12
     exploding_check_old = 0._real12
  else
     exploding_check = 1._real12
     exploding_check_old = 1._real12
  end if


!!!-----------------------------------------------------------------------------
!!! initialise random seed
!!!-----------------------------------------------------------------------------
  call random_seed(size=nseed)
  allocate(seed_arr(nseed))
  seed_arr = seed
  call random_seed(put=seed_arr)


!!!-----------------------------------------------------------------------------
!!! shuffle dataset
!!!-----------------------------------------------------------------------------
  if(shuffle_dataset)then
     write(6,*) "Shuffling training dataset..."
     call shuffle(input_images, labels, 4, seed)
     write(6,*) "Training dataset shuffled"
     if(verbosity.eq.-1)then
        write(6,*) "Check fort.11 and fort.12 to ensure data shuffling &
             &executed properly"
        do i=1,batch_size*2
           write(11,*) input_images(:,:,:,i) 
        end do
        write(12,*) labels
     end if
  end if


!!!-----------------------------------------------------------------------------
!!! initialise convolutional and pooling layers
!!!-----------------------------------------------------------------------------
  write(6,*) "Initialising CNN..."
  !! Initialise the convolution layer
  call cv_init(seed, num_layers = cv_num_filters, &
       kernel_size = cv_kernel_size, stride = cv_stride, &
       full_padding = trim(padding_method).eq."full")
  output_size = floor( (&
       image_size + 2.0 * maxval(convolution(:)%pad) - maxval(cv_kernel_size)&
       )/minval(cv_stride) ) + 1

  !! Initialise the pooling layer
  call pl_init(pool_kernel_size, pool_stride)
  num_pool = (output_size - pool_kernel_size) / pool_stride + 1
  input_size = num_pool**2 * output_channels
  lw_image_size = lbound(input_images,dim=1)
  up_image_size = ubound(input_images,dim=1)


!!!-----------------------------------------------------------------------------
!!! reformulate fully connected layers to include input and output layers
!!! ... user provides only hidden layers
!!!-----------------------------------------------------------------------------
  fc_num_layers = size(fc_num_hidden,dim=1) + 2
  allocate(tmp_num_hidden(fc_num_layers))
  tmp_num_hidden(1) = input_size
  tmp_num_hidden(2:fc_num_layers-1) = fc_num_hidden
  tmp_num_hidden(fc_num_layers) = num_classes
  call move_alloc(tmp_num_hidden, fc_num_hidden)


!!!-----------------------------------------------------------------------------
!!! initialise fully connected and softmax layers
!!!-----------------------------------------------------------------------------
  !! Initialise the fully connected layer
  call fc_init(seed, num_layers=fc_num_layers, &
       num_inputs=input_size, num_hidden=fc_num_hidden, &
       activation_function=activation_function)

  !! Initialise the softmax layer
  call sm_init(num_classes)
  write(6,*) "CNN initialised"


!!!-----------------------------------------------------------------------------
!!! allocate and initialise layer outputs and gradients
!!!-----------------------------------------------------------------------------
  allocate(cv_output(output_size, output_size, output_channels))
  allocate(pl_output(num_pool, num_pool, output_channels))
  allocate(fc_output(num_classes))
  allocate(sm_output(num_classes))
  cv_output = 0._real12
  pl_output = 0._real12
  fc_output = 0._real12
  sm_output = 0._real12

  allocate(fc_input(input_size))
  allocate(pl_output_rs(input_size))
  fc_input = 0._real12
  pl_output_rs = 0._real12

  allocate(cv_gradients(&
       lw_image_size:up_image_size,&
       lw_image_size:up_image_size,&
       output_channels))
  allocate(pl_gradients,mold=cv_output)
  allocate(fc_gradients_rs,mold=pl_output)
  allocate(sm_gradients(num_classes))
  cv_gradients = 0._real12
  pl_gradients = 0._real12
  fc_gradients_rs = 0._real12
  sm_gradients = 0._real12

  allocate(comb_cv_gradients(&
       lw_image_size:up_image_size,&
       lw_image_size:up_image_size,&
       output_channels))
  comb_cv_gradients = 0._real12

  allocate(fc_gradients(fc_num_layers))
  allocate(comb_fc_gradients(fc_num_layers))
  do l=1,fc_num_layers
     allocate(fc_gradients(l)%val(fc_num_hidden(l)))
     allocate(comb_fc_gradients(l)%val(fc_num_hidden(l)))
     fc_gradients(l)%val = 0._real12
     comb_fc_gradients(l)%val(:) = 0._real12
  end do


!!!-----------------------------------------------------------------------------
!!! if parallel, initialise slices
!!!-----------------------------------------------------------------------------
  !write(0,*) "IMAGE SIZE", lw_image_size,up_image_size
  !allocate(image_sample(&
  !     lw_image_size:up_image_size,&
  !     lw_image_size:up_image_size,&
  !     size(input_images,dim=3)))
#ifdef _OPENMP
  allocate(image_slice(&
       lw_image_size:up_image_size,&
       lw_image_size:up_image_size,&
       size(input_images,dim=3),batch_size))
  allocate(label_slice(batch_size))
#endif


!!!-----------------------------------------------------------------------------
!!! query system clock
!!!-----------------------------------------------------------------------------
  call system_clock(time, count_rate = clock_rate)


!!!-----------------------------------------------------------------------------
!!! training loop
!!! ... loops over num_epoch number of epochs
!!! ... i.e. it trains on the same datapoints num_epoch times
!!!-----------------------------------------------------------------------------
  write(6,*) "Starting training..."
  epoch_loop: do epoch = 1, num_epochs
     !!-------------------------------------------------------------------------
     !! batch loop
     !! ... split data up into minibatches for training
     !!-------------------------------------------------------------------------
     batch_loop: do batch = 1, num_batches


        !! set batch start and end index
        !!----------------------------------------------------------------------
        start_index = (batch - 1) * batch_size + 1
        end_index = batch * batch_size
#ifdef _OPENMP
        image_slice(:,:,:,:) = input_images(:,:,:,start_index:end_index)
        label_slice(:) = labels(start_index:end_index)
        start_index = 1
        end_index = batch_size
#endif


        !! reset (zero) summed gradients
        !! ... UNCOMMENT if running mini-batch training 
        !!----------------------------------------------------------------------
        if(batch_learning)then
           comb_cv_gradients = 0._real12
           do l=1,fc_num_layers
              comb_fc_gradients(l)%val(:) = 0._real12
           end do
        end if


        !! reinitialise variables
        !!----------------------------------------------------------------------
        sum_loss = 0._real12
        sum_accuracy = 0._real12


        !!----------------------------------------------------------------------
        !! sample loop
        !! ... test each sample and get gradients and losses from each
        !!----------------------------------------------------------------------
        !$OMP PARALLEL DO & !! ORDERED
        !$OMP& DEFAULT(NONE) &
        !$OMP& SHARED(network, convolution) &
        !$OMP& SHARED(image_slice, label_slice) &
        !$OMP& SHARED(input_size, batch_size) &
        !$OMP& SHARED(fc_clip, cv_clip, batch_learning, fc_num_layers) &
        !$OMP& PRIVATE(sample) &
        !$OMP& PRIVATE(cv_output, cv_gradients) &
        !$OMP& PRIVATE(pl_output, pl_gradients) &
        !$OMP& PRIVATE(fc_input, fc_output,fc_gradients, fc_gradients_rs) &
        !$OMP& PRIVATE(sm_output, sm_gradients) &
        !$OMP& PRIVATE(rtmp1, expected, exploding_check_old) &
        !$OMP& REDUCTION(+:comb_cv_gradients,sum_loss,sum_accuracy,exploding_check) &
        !$OMP& REDUCTION(sum_operator:comb_fc_gradients)
        train_loop: do sample = start_index, end_index


           !! Forward pass
           !!-------------------------------------------------------------------
#ifdef _OPENMP
           !image_sample = image_slice(:,:,:,sample)
           call cv_forward(image_slice(:,:,:,sample), cv_output)
#else
           !image_sample = input_images(:,:,:,sample)
           call cv_forward(input_images(:,:,:,sample), cv_output)
#endif
           call pl_forward(cv_output, pl_output)
           fc_input = reshape(pl_output, [input_size])
           if(normalise_pooling)&
                call linear_renormalise(fc_input)
           call fc_forward(fc_input, fc_output)
           call sm_forward(fc_output, sm_output)

  
           !! check for NaN and infinity
           !!-------------------------------------------------------------------
           if(any(isnan(sm_output)))then
              write(0,*) "ERROR: Softmax outputs are NaN"
              stop
           end if
           if(batch_learning)then
              exploding_check = exploding_check + sum(fc_output)
           else
              stop "ERROR: non-batch learning not yet parallelised"
              exploding_check_old = exploding_check
              exploding_check = sum(fc_output)
              !exploding_check=mean(fc_output)/exploding_check
              rtmp1 = abs(exploding_check/exploding_check_old)
              if(rtmp1.gt.1.E3_real12)then
                 write(0,*) "WARNING: FC outputs are expanding too quickly!"
                 write(0,*) "check:", sample,exploding_check,exploding_check_old      
                 write(0,*) "outputs:", fc_output
              elseif(rtmp1.lt.1.E-3_real12)then
                 write(0,*) "WARNING: FC outputs are vanishing too quickly!"
                 write(0,*) "check:", sample,exploding_check,exploding_check_old
                 write(0,*) "outputs:", fc_output
              end if
           end if

           
           !! compute loss and accuracy (for monitoring)
           !!-------------------------------------------------------------------
#ifdef _OPENMP
           expected = label_slice(sample)
#else
           expected = labels(sample)
#endif
           sum_loss = sum_loss + categorical_cross_entropy(sm_output, expected)
           sum_accuracy = sum_accuracy + compute_accuracy(sm_output, expected)


           !! Backward pass
           !!-------------------------------------------------------------------
           call sm_backward(sm_output, expected, sm_gradients)
           call fc_backward(fc_input, sm_gradients, fc_gradients, fc_clip)
           fc_gradients_rs = reshape(fc_gradients(1)%val,shape(fc_gradients_rs))
           call pl_backward(cv_output, fc_gradients_rs, pl_gradients)
           call cv_backward(image_sample, pl_gradients, &
                cv_gradients, cv_clip)


           !! if mini-batch ...
           !! ... sum gradients for mini-batch training
           !! if not mini-batch
           !! ... update weights and biases using optimization algorithm
           !! ... (gradient descent)
           !!-------------------------------------------------------------------
           if(batch_learning)then
              comb_cv_gradients = comb_cv_gradients + cv_gradients
              do l=1,fc_num_layers
                 comb_fc_gradients(l)%val = comb_fc_gradients(l)%val + &
                      fc_gradients(l)%val
              end do
#ifndef _OPENMP
           else
              !call cv_update(learning_rate, image_sample, &
              !     cv_gradients, &
              !     l1_lambda, l2_lambda, momentum)
              call cv_update(learning_rate, input_images(:,:,:,sample), &
                   cv_gradients, &
                   l1_lambda, l2_lambda, momentum)
              call fc_update(learning_rate, fc_input, fc_gradients, &
                   l1_lambda, l2_lambda, momentum, l_batch=batch_learning)
#endif
           end if


        end do train_loop
        !$OMP END PARALLEL DO


        !! Error checking and handling
        !!----------------------------------------------------------------------
        rtmp1 = 0._real12
        do l=1,fc_num_layers
           rtmp1 = rtmp1 + sum(abs(comb_fc_gradients(l)%val))
        end do
        if(rtmp1.lt.1.D-8)then
           write(0,*) "ERROR: FullyConnected gradients are zero"
           write(0,*) "Exiting..."
           stop
        end if


        !! Average accuracy and loss over batch size and store
        !!----------------------------------------------------------------------
        sum_loss = sum_loss / batch_size
        loss_history = cshift(loss_history, shift=-1, dim=1)
        loss_history(1) = sum_loss
        sum_accuracy = sum_accuracy / batch_size


        !! Check loss convergence
        !!----------------------------------------------------------------------
        if(abs(sum(loss_history)).lt.loss_threshold)then
           write(6,*) "Convergence achieved, accuracy threshold reached"
           write(6,*) "Exiting training loop"
           exit epoch_loop
        elseif(all(abs(loss_history-sum_loss).lt.plateau_threshold))then
           write(0,*) "sm_output", sm_output
           write(0,*) "sm_grad", sm_gradients
           write(0,*) "fc_gradients", fc_gradients(1)%val
           write(0,*) "ERROR: accuracy has remained constant for 10 runs"
           write(0,*) "Exiting..."
           stop
           exit epoch_loop
        end if


        !! if mini-batch ...
        !! ... update weights and biases using optimization algorithm
        !! ... (gradient descent)
        !!----------------------------------------------------------------------
        if(batch_learning)then
           exploding_check = (exploding_check/batch_size)
           if(epoch.gt.1.or.batch.gt.1)then
              rtmp1 = abs(exploding_check/exploding_check_old)
              if(rtmp1.gt.1.E3_real12)then
                 write(0,*) "WARNING: FC outputs are expanding too quickly!"
                 write(0,*) "check:", sample,exploding_check,exploding_check_old
              elseif(rtmp1.lt.1.E-3_real12)then
                 write(0,*) "WARNING: FC outputs are vanishing too quickly!"
                 write(0,*) "check:", exploding_check, exploding_check_old
              end if
           end if
           exploding_check_old = exploding_check
           exploding_check = 0._real12
           
           comb_cv_gradients = comb_cv_gradients/batch_size
           do l=1,fc_num_layers
              comb_fc_gradients(l)%val = comb_fc_gradients(l)%val/batch_size
           end do
           call cv_update(learning_rate, image_sample, &
                comb_cv_gradients, &
                l1_lambda, l2_lambda, momentum)
           call fc_update(learning_rate, fc_input, comb_fc_gradients, &
                l1_lambda, l2_lambda, momentum, l_batch=batch_learning)
        end if


        !! print batch results
        !!----------------------------------------------------------------------
        if(abs(verbosity).gt.0)then
           write(6,'("epoch=",I0,", batch=",I0,&
                &", learning_rate=",F0.3,", loss=",F0.3,", accuracy=",F0.3)') &
                epoch, batch, learning_rate, sum_loss, sum_accuracy
        end if


        !! time check
        !!----------------------------------------------------------------------
        if(verbosity.eq.-2)then
           time_old = time
           call system_clock(time)
           write(6,'("time check: ",I0," seconds")') (time-time_old)/clock_rate
           time_old = time
        end if


        !! check for user-name stop file
        !!----------------------------------------------------------------------
        if(stop_check())then
           write(0,*) "STOPCAR ENCOUNTERED"
           write(0,*) "Exiting training loop..."
           exit epoch_loop
        end if

     end do batch_loop


     !! print epoch summary results
     !!-------------------------------------------------------------------------
     if(verbosity.eq.0)then
        !!if(mod(epoch,20).eq.0.E0) &
        write(6,'("epoch=",I0,", batch=",I0,&
             &", learning_rate=",F0.3,", loss=",F0.3,", accuracy=",F0.3)') &
             epoch, batch, learning_rate, sum_loss, sum_accuracy
     end if


  end do epoch_loop


!!!-----------------------------------------------------------------------------
!!! print weights and biases of CNN to file
!!!-----------------------------------------------------------------------------
  cnn_file = '../cnn_layers.txt'
  open(unit=10,file=cnn_file,status='replace')
  close(10)
  call cv_write(cnn_file)
  call fc_write(cnn_file)


!!!-----------------------------------------------------------------------------
!!! testing loop
!!!-----------------------------------------------------------------------------
  test_loop: do sample = 1, num_samples_test

     call cv_forward(test_images(:,:,:,sample), cv_output)
     call pl_forward(cv_output, pl_output)
     fc_input = reshape(pl_output, [input_size])
     if(normalise_pooling)&
          call linear_renormalise(fc_input)
     call fc_forward(fc_input, fc_output)
     call sm_forward(fc_output, sm_output)


     !! compute loss and accuracy (for monitoring)
     !!-------------------------------------------------------------------------
     expected = test_labels(sample)
     sum_loss = sum_loss + categorical_cross_entropy(sm_output, expected)
     accuracy = compute_accuracy(sm_output, expected)


     !! print testing results
     !!-------------------------------------------------------------------------
     if(abs(verbosity).gt.1)then
        write(6,'(I4," Expected=",I3,", Got=",I3,", Accuracy=",F0.3)') &
             sample,expected-1, maxloc(sm_output,dim=1)-1, accuracy
     end if
     if(verbosity.lt.1)then
        write(0,*) sm_output
        write(0,*)
     end if

  end do test_loop


  overall_loss = real(sum_loss)/real(num_samples_test)
  write(6,'("Overall accuracy=",F0.5)') overall_loss



!!!#############################################################################
!!!#############################################################################
!!! * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * *  !!!
!!!#############################################################################
!!!#############################################################################

contains

!!!#############################################################################
!!! compute losses
!!! method: custom: RMSE-like???
!!!#############################################################################
  function compute_loss(output, expected) result(loss)
    implicit none
    real(real12), dimension(:), intent(in) :: output
    integer, intent(in) :: expected
    integer :: i
    real(real12) :: loss, total

    !! Compute the cross-entropy loss
    total = 0._real12
    do i=1,size(output)
       if(i.eq.expected)then
          total = total + (output(i) - 1._real12)**2.E0
       else
          total = total + output(i)**2.E0
       end if
    end do
    !loss = -log(output(expected))
    !! ERROR: total = 0 means no loss, but log(0) = INF
    !loss = -log(total)
    loss = total

  end function compute_loss
!!!#############################################################################


!!!#############################################################################
!!! compute losses
!!! method: categorical cross entropy
!!!#############################################################################
  function categorical_cross_entropy(output, expected) result(loss)
    implicit none
    real(real12), dimension(:), intent(in) :: output
    integer, intent(in) :: expected
    real(real12) :: loss, epsilon

    epsilon = 1.E-10_real12
    loss = -1._real12/real(size(output, dim=1),real12) * log(output(expected)+epsilon)

  end function categorical_cross_entropy
!!!#############################################################################


!!!#############################################################################
!!! compute loss derivative
!!! method: categorical cross entropy
!!! this is handled by the softmax backward subroutine
!!!#############################################################################
  subroutine categorical_cross_entropy_derivative(output, expected, gradient)
    implicit none
    integer, intent(in) :: expected
    real(real12), dimension(:), intent(in) :: output
    real(real12), dimension(:), intent(out) :: gradient
    
    gradient = output
    gradient(expected) = output(expected) - 1._real12

  end subroutine categorical_cross_entropy_derivative
!!!#############################################################################


!!!#############################################################################
!!! compute accuracy
!!! this only works (and is only valid for?) categorisation problems
!!!#############################################################################
  function compute_accuracy(output, expected) result(accuracy)
    implicit none
    real(real12), dimension(:), intent(in) :: output
    integer, intent(in) :: expected
    real(real12) :: accuracy

    !if(any(isnan(output)))then
    !   write(0,*) "Output is NaN"
    !   stop
    !end if

    !! Compute the accuracy
    if (output(expected).eq.maxval(output)) then
       accuracy = 1._real12
    else
       accuracy = 0._real12
    end if

    if(isnan(accuracy))then
       write(0,*) "ERROR: Accuracy is NaN"
       stop
    end if

  end function compute_accuracy
!!!#############################################################################


!!!#############################################################################
!!! read mnist dataset
!!!#############################################################################
  subroutine read_mnist(file,images,labels,kernel_size,image_size,padding_method)
    use misc, only: icount
    use misc_ml, only: get_padding_half
    implicit none
    integer :: i, j, k, Reason, unit
    integer :: num_samples, num_pixels, padding
    character(2048) :: buffer
    character(:), allocatable :: t_padding_method

    integer, intent(out) :: image_size
    integer, optional, intent(in) :: kernel_size
    character(*), optional, intent(in) :: padding_method
    character(1024), intent(in) :: file
    real(real12), dimension(:,:,:,:), allocatable, intent(out) :: images
    integer, dimension(:), allocatable, intent(out) :: labels


!!!-----------------------------------------------------------------------------
!!! open file
!!!-----------------------------------------------------------------------------
    unit = 10
    open(unit=unit,file=file)


!!!-----------------------------------------------------------------------------
!!! count number of samples
!!!-----------------------------------------------------------------------------
    i = 0
    line_count: do
       i = i + 1
       read(unit,'(A)',iostat=Reason) buffer
       if(Reason.ne.0)then
          num_samples = i - 1
          exit line_count
       elseif(i.gt.90000)then
          write(0,*) "Too many lines to read in file provided (over 90000)"
          write(0,*) "Exiting..."
          stop 0
       elseif(i.eq.1)then
          num_pixels = icount(buffer,",") - 1
       end if
    end do line_count


!!!-----------------------------------------------------------------------------
!!! calculate size of image
!!!-----------------------------------------------------------------------------
    image_size = nint(sqrt(real(num_pixels,real12)))


!!!-----------------------------------------------------------------------------
!!! rewind file and allocate labels
!!!-----------------------------------------------------------------------------
    rewind(unit)
    allocate(labels(num_samples))


!!!-----------------------------------------------------------------------------
!!! handle padding type name
!!!-----------------------------------------------------------------------------
    !! none  = alt. name for 'valid'
    !! zero  = alt. name for 'same'
    !! symmetric = alt.name for 'replication'
    !! valid = no padding
    !! same  = maintain spatial dimensions
    !!         ... (i.e. padding added = (kernel_size - 1)/2)
    !!         ... defaults to zeros in the padding
    !! full  = enough padding for filter to slide over every possible position
    !!         ... (i.e. padding added = (kernel_size - 1)
    !! circular = maintain spatial dimensions
    !!            ... wraps data around for padding (periodic)
    !! reflection = maintains spatial dimensions
    !!              ... reflect data (about boundary index)
    !! replication = maintains spatial dimensions
    !!               ... reflect data (boundary included)
    if(present(padding_method))then
       t_padding_method = trim(padding_method)
100    select case(t_padding_method)
       case("none")
          t_padding_method = "valid"
          goto 100
       case("zero")
          t_padding_method = "same"
          goto 100
       case("half")
          t_padding_method = "same"
          goto 100
       case("symmetric")
          t_padding_method = "replication"
          goto 100
       case("valid")
          write(6,*) "Padding type: 'valid' (all possible positions)"
       case("same")
          write(6,*) "Padding type: 'same' (pad with zeros)"
       case("circular")
          write(6,*) "Padding type: 'same' (circular padding)"
       case("full")
          write(6,*) "Padding type: 'full' (all possible positions)"
       case("reflection")
          write(6,*) "Padding type: 'reflection' (reflect on boundary)"
       case("replication")
          write(6,*) "Padding type: 'replication' (reflect after boundary)"
       case default
          stop "ERROR: padding type '"//t_padding_method//"' not known"
       end select
    else
       t_padding_method = "same"
    end if
    

!!!-----------------------------------------------------------------------------
!!! allocate data set
!!! ... if appropriate, add padding
!!!-----------------------------------------------------------------------------
    !! dim=1: image width in pixels
    !! dim=2: image height in pixels
    !! dim=3: image number of channels (1 due to black-white images)
    !! dim=4: number of images
    if(t_padding_method.eq."valid")then
       padding = 0
       allocate(images(image_size, image_size, 1, num_samples))
    elseif(present(kernel_size))then

       !! calculate padding width
       !!-----------------------------------------------------------------------
       select case(t_padding_method)
       case("full")
          padding = kernel_size - 1
       case default
          padding = get_padding_half(kernel_size)
       end select

       allocate(images(&
            -padding+1:image_size+padding + (1-mod(kernel_size,2)),&
            -padding+1:image_size+padding + (1-mod(kernel_size,2)),&
            1, num_samples))

       !! initialise padding for constant padding types (i.e. zeros)
       !!-----------------------------------------------------------------------
!!! LATER MAKE THE CONSTANT AN OPTIONAL VALUE
       select case(t_padding_method)
       case ("same")
          images = 0._real12
       case("full")
          images = 0._real12
       end select
       
    else
       stop "ERROR: kernel_size not provided to read_mnist for padding &
            &method "//t_padding_method
    end if


!!!-----------------------------------------------------------------------------
!!! read in dataset
!!!-----------------------------------------------------------------------------
    do i=1,num_samples
       read(unit,*) labels(i), ((images(j,k,1,i),k=1,image_size),j=1,image_size)
    end do

    close(unit)


!!!-----------------------------------------------------------------------------
!!! populate padding
!!!-----------------------------------------------------------------------------
    select case(t_padding_method)
    case ("circular")
       images(-padding+1:0:1, 1:image_size, :, :) = &
            images(image_size-padding+1:image_size:1, 1:image_size, :, :)
       images(image_size+1:image_size+padding:1, 1:image_size, :, :) = &
            images(1:1+padding-1:1, 1:image_size, :, :)

       images(:, -padding+1:0:1, :, :) = &
            images(:, image_size-padding+1:image_size:1, :, :)
       images(:, image_size+1:image_size+padding:1, :, :) = &
            images(:, 1:1+padding-1:1, :, :)
    case("reflection")
       images(0:-padding+1:-1, 1:image_size, :, :) = &
            images(2:2+padding-1:1, 1:image_size, :, :)
       images(image_size+1:image_size+padding:1, 1:image_size, :, :) = &
            images(image_size-1:image_size-padding:-1, 1:image_size, :, :)

       images(:, 0:-padding+1:-1, :, :) = &
            images(:, 2:2+padding-1:1, :, :)
       images(:, image_size+1:image_size+padding:1, :, :) = &
            images(:, image_size-1:image_size-padding:-1, :, :)
    case("replication")
       images(0:-padding+1:-1, 1:image_size, :, :) = &
            images(1:1+padding-1:1, 1:image_size, :, :)
       images(image_size+1:image_size+padding:1, 1:image_size, :, :) = &
            images(image_size:image_size-padding+1:-1, 1:image_size, :, :)

       images(:, 0:-padding+1:-1, :, :) = &
            images(:, 1:1+padding-1:1, :, :)
       images(:, image_size+1:image_size+padding:1, :, :) = &
            images(:, image_size:image_size-padding+1:-1, :, :)
    end select
    

!!!-----------------------------------------------------------------------------
!!! increase label values to match fortran indices
!!!-----------------------------------------------------------------------------
    images = images/255._real12
    labels = labels + 1
    write(6,*) "Data read"


  end subroutine read_mnist
!!!#############################################################################

end program ConvolutionalNeuralNetwork
!!!###################################################################################
