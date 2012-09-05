package WebworkBridge::Importer::CourseUpdater;

##### Library Imports #####
use strict;
use warnings;

use Time::HiRes qw/gettimeofday/;
use Date::Format;

use WeBWorK::CourseEnvironment;
use WeBWorK::DB;
use WeBWorK::Debug;
use WeBWorK::Utils qw(runtime_use readFile cryptPassword);
use WeBWorK::DB::Utils qw(initializeUserProblem);

use WebworkBridge::Importer::Error;

# Constructor
sub new
{
	my ($class, $r, $course_ref, $students_ref) = @_;
	my $self = {
		r => $r,
		course => $course_ref,
		students => $students_ref
	};
	bless $self, $class;
	return $self;
}

# it should be safe to require that we have the correctly init course
# environment with the necessary course context
sub updateCourse
{
	my $self = shift;
	my $r = $self->{r};
	my $ce = $r->ce;
	my $db = new WeBWorK::DB($ce->{dbLayout});

	debug(("-" x 80) . "\n");
	debug("Starting Student Update");
	# Perform Setup
	my $courseid = $self->{course}->{name}; # the course we're updating
	my $courseprofs = $self->{course}->{profid}; # the profs of this course, csv
	my @students = @{$self->{students}}; # deref pointer

	if (!$ce->{"courseName"})
	{ # CE does not have the course loaded, need to remake
		$ce = WeBWorK::CourseEnvironment->new({
				%WeBWorK::SeedCE,
				courseName => $courseid
			});
	}

	$db = new WeBWorK::DB($ce->{dbLayout});
	
	# Get already existing users in the database
	my @userIDs;
	my @usersList;
	my @permsList;
	eval 
	{ 
		@userIDs = $db->listUsers(); 
		@usersList = $db->getUsers(@userIDs);
		@permsList = $db->getPermissionLevels(@userIDs);
	};
	if ($@)
	{
		return "Unable to list existing users for course: $courseid\n"
	}
	my %perms = map {($_->user_id => $_ )} @permsList;
	my %users = map {($_->user_id => $_ )} @usersList;

	# Update has 3 components 
	#	1. Check existing users to see if we have anyone who dropped the course
	#		but decided to re-register or if their info needs updating.
	#	2. Add newly enrolled users
	#	3. Mark dropped students as "dropped"

	# Update components 1,2: Check existing users 
	debug("Checking for new students...\n");
	foreach (@students)
	{
		my $id = $_->{'loginid'};
		if (exists($users{$id}))
		{ # Update component 1: Update existing users
			$self->updateUser($users{$id}, $_, $perms{$id}, $db);
			delete($users{$id}); # this student is now safe from being dropped
		}
		else
		{ # Update component 2: newly enrolled student, have to add
			my $ret = $self->addUser($_, $db, $courseprofs);
			$self->addlog("Student $id joined $courseid");
			if ($ret)
			{
				return $ret;
			}
		}
	}

	debug("Checking for dropped students...\n");
	# Update component 3: Mark dropped students as dropped
	while (my ($key, $val) = each(%users))
	{ # any students left in %users has been dropped
		my $person = $val;
		# only users with status C or P should be tracked by enrolment sync
		if (($person->status() eq "C" || $person->status() eq "P") && 
			$key ne "admin")
		{ 
			$person->status("D");
			$db->putUser($person);
			$self->addlog("Student $key dropped $courseid");
			#$db->deleteUser($key); # we might delete users in the future
		}
	}
	debug("Student Update From Vista Finished!\n");
	debug(("-" x 80) . "\n");
	return 0;
}

##### Helper Functions #####
sub updateUser
{
	# permission is the current permission object, which can be updated
	# if $newInfo contains new permission
	my ($self, $oldInfo, $newInfo, $permission, $db) = @_;
	my $ce = $self->{r}->ce;
	my $courseid = $self->{course}->{name}; # the course we're updating
	my $id = $oldInfo->user_id();

	# Do the simple updates first since they can be batched
	my $update = 0;
	# Update student id
	if ($newInfo->{'studentid'} ne $oldInfo->student_id())
	{
		$oldInfo->student_id($newInfo->{'studentid'});
		$update = 1;
	}
	# Update email, only students get updated, and the new email address 
	# has to be non-empty
	if (defined($newInfo->{'email'}) &&
		$newInfo->{'permission'} == $ce->{userRoles}{student} &&
		$newInfo->{'email'} ne "" &&
		$newInfo->{'email'} ne $oldInfo->email_address())
	{
		$oldInfo->email_address($newInfo->{'email'});
		$update = 1;
	}
	# Update first name
	if ($newInfo->{'firstname'} ne $oldInfo->first_name())
	{
		$oldInfo->first_name($newInfo->{'firstname'});
		$update = 1;
	}
	# Update last name
	if ($newInfo->{'lastname'} ne $oldInfo->last_name())
	{
		$oldInfo->last_name($newInfo->{'lastname'});
		$update = 1;
	}
	# Batch update info
	if ($update)
	{
		$db->putUser($oldInfo);
	}
	# Update permissions
	if ($newInfo->{'permission'} != $permission->permission())
	{
		$permission->permission($newInfo->{'permission'});
		$db->putPermissionLevel($permission);
	}
	# Update status
	if ($oldInfo->status() eq "D")
	{ # this person dropped the course but re-registered
		if ($permission->permission() <= $ce->{userRoles}{student})
		{
			$oldInfo->status("C");
			$db->putUser($oldInfo);
			$self->addlog("Student $id rejoined $courseid");
			# assign all visible homeworks to user
			$self->assignAllVisibleSetsToUser($id, $db);
		}
		else
		{
			$oldInfo->status("P");
			$db->putUser($oldInfo);
			$self->addlog("Teaching staff $id rejoined $courseid");
		}
	}
}

sub addUser
{
	my ($self, $new_user_info, $db, $profs) = @_;
	my $ce = $self->{r}->ce;
	my @profid = split(/,/, $profs); # array of profs in the course
	my $id = $new_user_info->{'loginid'};
	my $status = "C"; # defaults to enroled
	my $role = $ce->{userRoles}{student}; # defaults to student

	# modify status and role if user is a teaching staff
	$role = $new_user_info->{'permission'};
	if ($role == $ce->{userRoles}{professor} ||
		$role == $ce->{userRoles}{ta})
	{
		$status = "P"; # teaching staff status, doesn't get homework or graded
	}
	
	# student record
	my $new_user = $db->{user}->{record}->new();
	$new_user->user_id($id);
	$new_user->first_name($new_user_info->{'firstname'});
	$new_user->last_name($new_user_info->{'lastname'});
	$new_user->email_address($new_user_info->{'email'});
	$new_user->status($status);
	$new_user->student_id($new_user_info->{'studentid'});
	
	# password record
	my $cryptedpassword;
	if ($new_user_info->{'password'})
	{
		$cryptedpassword = cryptPassword($new_user_info->{'password'});
	}
	else
	{
		$cryptedpassword = cryptPassword($new_user->student_id());
	}
	my $password = $db->newPassword(user_id => $id);
	$password->password($cryptedpassword);
	
	# permission record
	my $permission = $db->newPermissionLevel(user_id => $id, 
		permission => $role);

	# commit changes to db
	eval{ $db->addUser($new_user); };
	if ($@)
	{
		return "Add user for $id failed!\n";
	}
	eval { $db->addPassword($password); };
	if ($@)
	{
		return "Add password for $id failed!\n";
	}
	eval { $db->addPermissionLevel($permission); };
	if ($@)
	{
		return "Add permission for $id failed!\n";
	}

	if ($role ne $ce->{userRoles}{professor})
	{ # is a student, so must have all the homeworks
		# assign all visible homeworks to user
		$self->assignAllVisibleSetsToUser($id, $db);
	}
	return 0;
}

sub addlog
{
	my ($self, $msg) = @_;

	my ($sec, $msec) = gettimeofday;
	my $date = time2str("%a %b %d %H:%M:%S.$msec %Y", $sec);

	$msg = "[$date] $msg\n";

	my $logfile = $self->{r}->ce->{bridge}{studentlog};
	if ($logfile ne "")
	{
		if (open my $f, ">>", $logfile)
		{
			print $f $msg;
			close $f;
		}
		else
		{
			debug("Error, unable to open student updates log file '$logfile' in append mode: $!");
		}
	}
	else
	{
		debug("Warning, student updates log file not configured.");
		print STDERR $msg;
	}
}

# Taken from assignAllSetsToUser() in WeBWorK::ContentGenerator::Instructor
sub assignAllVisibleSetsToUser {
	my ($self, $userID, $db) = @_;
	
	my @globalSetIDs = $db->listGlobalSets;
	my @GlobalSets = $db->getGlobalSets(@globalSetIDs);
	
	my @results;
	
	my $i = 0;
	foreach my $GlobalSet (@GlobalSets) {
		if (not defined $GlobalSet) {
			warn "record not found for global set $globalSetIDs[$i]";
		} 
		elsif ($GlobalSet->visible) {
			my @result = $self->assignSetToUser($userID, $GlobalSet, $db);
			push @results, @result if @result;
		}
		$i++;
	}
	
	return @results;
}

# Taken and modified from WeBWorK::ContentGenerator::Instructor
sub assignSetToUser {
	my ($self, $userID, $GlobalSet, $db) = @_;
	my $setID = $GlobalSet->set_id;
	
	my $UserSet = $db->newUserSet;
	$UserSet->user_id($userID);
	$UserSet->set_id($setID);
	
	my @results;
	my $set_assigned = 0;
	
	eval { $db->addUserSet($UserSet) };
	if ($@) {
		if ($@ =~ m/user set exists/) {
			push @results, "set $setID is already assigned to user $userID.";
			$set_assigned = 1;
		} else {
			die $@;
		}
	}
	
	my @GlobalProblems = grep { defined $_ } $db->getAllGlobalProblems($setID);
	foreach my $GlobalProblem (@GlobalProblems) {
		my @result = $self->assignProblemToUser($userID, $GlobalProblem, $db);
		push @results, @result if @result and not $set_assigned;
	}
	
	return @results;
}

# Taken and modified from WeBWorK::ContentGenerator::Instructor
sub assignProblemToUser {
	my ($self, $userID, $GlobalProblem, $db) = @_;
	
	my $UserProblem = $db->newUserProblem;
	$UserProblem->user_id($userID);
	$UserProblem->set_id($GlobalProblem->set_id);
	$UserProblem->problem_id($GlobalProblem->problem_id);
	my $seed; # yes, I know it's empty, just needed a null value for this 
	initializeUserProblem($UserProblem, $seed);
	
	eval { $db->addUserProblem($UserProblem) };
	if ($@) {
		if ($@ =~ m/user problem exists/) {
			return "problem " . $GlobalProblem->problem_id
				. " in set " . $GlobalProblem->set_id
				. " is already assigned to user $userID.";
		} else {
			die $@;
		}
	}
	
	return ();
}

1;
