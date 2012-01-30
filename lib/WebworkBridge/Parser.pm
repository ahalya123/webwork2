package WebworkBridge::Parser;

##### Library Imports #####
use strict;
use warnings;

use WeBWorK::Debug;

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

sub parse
{
	my ($self, $param) = @_;
	die "Not implemented";
}

sub parseStudent
{
	my ($self, $param) = @_;
	die "Not implemented";
}

sub parseCourse
{
	my ($self, $param) = @_;
	die "Not implemented";
}

sub getCourseName
{
	my ($self, $course, $section) = @_;
	my $r = $self->{r};
	my $ce = $r->ce;

	# read configuration to see if there are any custom mappings we
	# should use instead
	my $origname;
	if ($section)
	{	
		$origname = $course . ' - ' . $section;
	}
	else
	{
		$origname = $course;
	}

	for my $key (keys %{$ce->{bridge}{custom_course_mapping}})
	{
		if ($origname eq $key)
		{
			my $val = $ce->{bridge}{custom_course_mapping}{$key};
			debug("Using mapping for course '$origname' to '$val'");
			return sanitizeCourseName($val);
		}
	}

	# if no configuration, then we build our own course name 
	$section ||= '';
	my $sectionnum = $section;
	$sectionnum =~ m/(\d\d\d[A-Za-z]|\d\d\d)/g;
	$sectionnum = $1;

	my $ret;
	if ($sectionnum)
	{
		$ret = $course .'-'. $sectionnum;
	}
	elsif ($section)
	{
		$ret = $course . '-' . $section;	
	}
	else
	{
		$ret = $course;
	}
	$ret = sanitizeCourseName($ret);

	return $ret;
}

sub sanitizeCourseName
{
	my $course = shift;
	$course =~ s/[^a-zA-Z0-9_-]//g;
	$course = substr($course,0,40); # needs to fit mysql table name limits
	# max length of a mysql table name is 64 chars, however, webworks stick
	# additional characters after the course name, so, to be safe, we'll
	# have an error margin of 24 chars.
	return $course;
}

1;
