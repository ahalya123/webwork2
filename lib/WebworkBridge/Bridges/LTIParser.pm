package WebworkBridge::Bridges::LTIParser;
use base qw(WebworkBridge::Parser);

use strict;
use warnings;

use XML::Simple;
use WebworkBridge::Importer::Error;
use WeBWorK::Debug;
use Data::Dumper;

##### Exported Functions #####
sub new
{
	my ($class, $r, $course_ref, $students_ref) = @_;
	my $self = $class->SUPER::new($r, $course_ref, $students_ref);
	bless $self, $class;
	return $self;
}

sub parse
{
	my ($self, $param) = @_;
	my $ce = $self->{r}->ce;
	my $course = $self->{course};
	# named students, but is actually the list of all users in the course
	my $students = $self->{students}; 
	%{$course} = ();
	@{$students} = ();

	my $xml = new XML::Simple;

	my $data = $xml->XMLin($param, SuppressEmpty=>'');

	# only one person in the course
	if ($data->{'statusinfo'}{'codemajor'} ne 'Success')
	{ # check status code
		return error("Failed to retrieve roster.", "#e001");
	}

	my @members = $data->{'memberships'}{'member'};

	# xml parser creates different data structs if more than 1 member
	if (ref($data->{'memberships'}{'member'}) eq 'ARRAY')
	{
		# Note that the explicit cast is necessary, otherwise it throws
		# a bad index error in the foreach loop. The explicit cast is not
		# necessary if we only have a single member in the course, hence
		# we only cast if there are more than one members in the course.
		@members = @{$data->{'memberships'}{'member'}};
	}

	$course->{'profid'} = ""; # Initialize profid to empty string

	foreach(@members)
	{ # process members
		my %tmp = $self->parseUser($_);
		# assign appropriate permissions based on roles
		my $roles = $_->{'roles'};
		if ($roles =~ /instructor/i ||
			$roles =~ /contentdeveloper/i)
		{ # make note of the instructor for later
			$course->{'profid'} = $_->{'person_sourcedid'} . ',' . 
				$course->{'profid'};
			$tmp{'permission'} = $ce->{userRoles}{professor};
		}
		elsif ($roles =~ /teachingassistant/i) 
		{
			$tmp{'permission'} = $ce->{userRoles}{ta};
		}
		else
		{
			$tmp{'permission'} = $ce->{userRoles}{student};
		}
		# store user info
		push(@{$students}, \%tmp);
	}
	$course->{'profid'} = substr($course->{'profid'}, 0, -1); # rm extra comma 

	return 0;
}

##### Helper Functions #####

sub parseUser
{
	my ($self, $tmp) = @_;
	my %param = %{$tmp};
	my %student;
	$student{'firstname'} = $param{'person_name_given'};
	$student{'lastname'} = $param{'person_name_family'};
	# convert from internal perl UTF8 to binary UTF8, note that this means
	# I'm expecting these to go straight into the database, not be used in
	# any more perl ops
	utf8::encode($student{'firstname'});
	utf8::encode($student{'lastname'});
	$student{'studentid'} = $param{'user_id'};
	$student{'loginid'} = $param{'person_sourcedid'};
	$student{'sourcedid'} = $param{'lis_result_sourcedid'};
	$student{'email'} = $param{'person_contact_email_primary'};
	$student{'password'} = "";
	return %student;
}

# test code
#open FILE, "test.xml" or die "Cannot open XML file. $!";
#
#my $input = join("",<FILE>);
#
#my %course = ();
#my @students = ();
#
#parse($input, \%course, \@students);
#
#$Data::Dumper::Indent = 3;
#print "Course Info: \n";
#print Dumper(\%course);
#
#print "\n\nStudents List: \n";
#print Dumper(\@students);

1;

