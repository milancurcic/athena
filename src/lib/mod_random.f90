!!!#############################################################################
!!! Code written by Ned Thaddeus Taylor
!!! Code part of the ATHENA library - a feedforward neural network library
!!!#############################################################################
!!! module contains random number generator initialisation
!!! module contains the following procedures:
!!! - random_setup - seed random number generator from seed vector or randomly
!!!#############################################################################
module random
  implicit none
  logical :: l_random_initialised=.false.

  private

  public :: random_setup


contains

!!!#############################################################################
!!! seed random number generator from vector of seeds
!!!#############################################################################
  subroutine random_setup(seed, num_seed, restart, already_initialised)
    implicit none
    integer, dimension(..), optional, intent(in) :: seed !dimension(..1)
    integer, optional, intent(in) :: num_seed
    logical, optional, intent(in) :: restart
    logical, optional, intent(out) :: already_initialised

    integer :: l
    integer :: itmp1
    integer :: num_seed_
    logical :: restart_
    integer, allocatable, dimension(:) :: seed_arr

    !! check if restart is defined
    if(present(restart))then
       restart_ = restart       
    else
       restart_ = .false.
    end if
    if(present(already_initialised)) already_initialised = .false.

    !! define number of seeds
    if(present(num_seed))then
       if(present(seed))then
          select rank(seed)
          rank(0)
             num_seed_ = num_seed
          rank(1)
             if(size(seed,dim=1).ne.1.and.size(seed,dim=1).ne.num_seed)then
                write(0,*) "ERROR: seed and num_seed provided to random_setup"
                write(0,*) " Cannot decide which to listen to"
                stop "Exiting..."
             end if
          end select
       else
          num_seed_ = num_seed
       end if
    else
       if(present(seed))then
          num_seed_ = size(seed,dim=1)
       else
          num_seed_ = 1
       end if
    end if

    !! check if already initialised
    if(l_random_initialised.and..not.restart_)then
       if(present(already_initialised)) already_initialised = .true.
       return !! no need to initialise if already initialised
    else
       call random_seed(size=num_seed_)
       allocate(seed_arr(num_seed_))
       if(present(seed))then
          select rank(seed)
          rank(0)
             seed_arr = seed
          rank(1)
             if(size(seed,dim=1).gt.1)then
                seed_arr = seed
             else
                seed_arr = seed(1)
             end if
          end select
       else
          call system_clock(count=itmp1)
          seed_arr = itmp1 + 37* (/ (l-1,l=1,num_seed_) /)
       end if
       call random_seed(put=seed_arr)
       l_random_initialised = .true.
    end if
    
  end subroutine random_setup
!!!#############################################################################

end module random
!!!#############################################################################
